<#
.SYNOPSIS
    夜间 MR 评审队列：探测远端 MR，逐个用 traecli 做只读评审，早上看报告。

.DESCRIPTION
    这是一个「最小闭环」实现，刻意只做三件事：
      1. 用 git 协议探测 MR（不需要任何 API token）
      2. 用 traecli exec 做只读评审（沙箱 read-only，改不了任何东西）
      3. 把结论汇总成 index.md

    刻意**不做**的事：自动提交、自动建 MR、自动合并。
    那些既需要凭证，在生产环境里也不该自动化。

.PARAMETER Repo
    本地仓库路径（要有 origin 远程）。

.PARAMETER Base
    diff 的基线分支。你们的 PR 目标分支是 uat，所以默认 uat。

.PARAMETER MaxItems
    一晚最多处理几个。并发只有 2，一次跑太多没意义，还会互相排队。

.PARAMETER DryRun
    只看会处理哪些 MR，不真的跑。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File night-review.ps1 -Repo D:\work\myproject -DryRun

.EXAMPLE
    # 下班前挂到任务计划程序
    powershell -ExecutionPolicy Bypass -File night-review.ps1 -Repo D:\work\myproject -MaxItems 2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Base = 'main',
    [string]$OutRoot = (Join-Path $env:USERPROFILE 'ai-reviews'),
    [int]$MaxItems = 3,
    [string]$Model = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Msg)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg) -ForegroundColor Cyan
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $enc = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# ---------------------------------------------------------------- 前置检查

$repoRoot = (Resolve-Path -LiteralPath $Repo).Path

$templatePath = Join-Path $PSScriptRoot 'prompts\review-mr.md'
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw ("找不到提示词模板：{0}" -f $templatePath)
}
$template = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)

if (-not (Test-Path -LiteralPath $OutRoot)) {
    New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null
}
$statePath = Join-Path $OutRoot 'state.json'
$state = @{}
if (Test-Path -LiteralPath $statePath) {
    $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $raw.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
}

# ---------------------------------------------------------------- 探测 MR 引用

Write-Step '探测远端 PR/MR 引用 ...'

# GitLab 用 refs/merge-requests/<iid>/head，Gitee/GitHub 用 refs/pull/<iid>/head。
# 两个都试，命中哪个用哪个 —— 全部走 git 协议，不需要 API token。
$patterns = @(
    @{ Kind = 'merge-requests'; Glob = 'refs/merge-requests/*/head' },
    @{ Kind = 'pull'; Glob = 'refs/pull/*/head' }
)

$chosen = $null
$lsOut = @()
foreach ($pat in $patterns) {
    $tmp = @(& git -C $repoRoot ls-remote origin $pat.Glob 2>$null)
    if ($LASTEXITCODE -eq 0 -and $tmp.Count -gt 0) {
        $chosen = $pat
        $lsOut = $tmp
        break
    }
}

if ($null -eq $chosen) {
    Write-Host '没探测到 MR 引用。手动确认你们的平台用哪个命名空间：' -ForegroundColor Yellow
    Write-Host ('    git -C "{0}" ls-remote origin | findstr /i "refs/"' -f $repoRoot) -ForegroundColor Yellow
    Write-Host '找到规律后，把 glob 加进本脚本的 $patterns。' -ForegroundColor Yellow
    return
}

Write-Step ('识别到 {0} 风格，引用命名空间：{1}' -f $chosen.Kind, $chosen.Glob)

$rxIid = [regex]('^refs/' + $chosen.Kind + '/(\d+)/head$')
$items = New-Object System.Collections.Generic.List[object]
foreach ($line in $lsOut) {
    $m = [regex]::Match($line, '^([0-9a-fA-F]{40})\s+(\S+)$')
    if (-not $m.Success) { continue }
    $ref = $m.Groups[2].Value
    $im = $rxIid.Match($ref)
    if (-not $im.Success) { continue }
    $items.Add([pscustomobject]@{
        Iid = [int]$im.Groups[1].Value
        Ref = $ref
        Sha = $m.Groups[1].Value
    })
}

# 只挑新增或 sha 变了的。已评过的记在 state.json 里，不再重复花 token。
$changed = @($items | Where-Object { $state[$_.Ref] -ne $_.Sha })
$todo = @($changed | Sort-Object Iid -Descending | Select-Object -First $MaxItems)

Write-Step ('远端 MR 共 {0} 个，新增/有更新 {1} 个，本次处理 {2} 个。' -f `
        $items.Count, $changed.Count, $todo.Count)

if ($DryRun) {
    Write-Host ''
    if ($todo.Count -eq 0) { Write-Host 'DryRun —— 没有需要处理的 MR。' -ForegroundColor Yellow }
    else {
        Write-Host 'DryRun —— 将处理以下 MR：' -ForegroundColor Yellow
        foreach ($it in $todo) {
            Write-Host ('    #{0}  {1}' -f $it.Iid, $it.Ref)
        }
    }
    Write-Host ''
    Write-Host ('命令形态：traecli exec --sandbox read-only --ask-for-approval never -C "{0}" -o <文件> -' -f $repoRoot) -ForegroundColor DarkGray
    return
}

# ---------------------------------------------------------------- 逐个评审

if ($todo.Count -gt 0 -and -not (Get-Command traecli -ErrorAction SilentlyContinue)) {
    throw '找不到 traecli 命令。先在终端确认 `traecli --version` 能跑，再挂夜间任务。'
}

$dayDir = Join-Path $OutRoot (Get-Date -Format 'yyyy-MM-dd')
if (-not (Test-Path -LiteralPath $dayDir)) {
    New-Item -ItemType Directory -Path $dayDir -Force | Out-Null
}

foreach ($it in $todo) {
    $localRef = 'refs/ai/mr-{0}' -f $it.Iid
    Write-Step ('抓取 MR #{0} ...' -f $it.Iid)

    & git -C $repoRoot fetch --quiet --no-tags origin ('+{0}:{1}' -f $it.Ref, $localRef) 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ('fetch 失败，跳过 #{0}' -f $it.Iid)
        continue
    }

    $prompt = $template.Replace('{{IID}}', [string]$it.Iid).Replace('{{BASE}}', $Base)
    $promptFile = Join-Path $env:TEMP ('ai-review-{0}.md' -f $it.Iid)
    Write-Utf8 -Path $promptFile -Text $prompt

    $dest = Join-Path $dayDir ('mr-{0}.md' -f $it.Iid)
    $cliArgs = @(
        'exec',
        '--sandbox', 'read-only',
        '--ask-for-approval', 'never',
        '--ephemeral',
        '-C', $repoRoot,
        '-o', $dest,
        '-'
    )
    if ($Model) { $cliArgs += @('-m', $Model) }

    Write-Step ('评审 #{0} 中，预计 10~40 分钟。发起后请离开，不要盯。' -f $it.Iid)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # `-` 表示从标准输入读提示词；提示词放文件里，方便你随时改、也方便进 git
    Get-Content -LiteralPath $promptFile -Raw -Encoding UTF8 | & traecli @cliArgs
    $code = $LASTEXITCODE
    $sw.Stop()

    if ($code -eq 0 -and (Test-Path -LiteralPath $dest)) {
        $state[$it.Ref] = $it.Sha
        Write-Step ('#{0} 完成，耗时 {1:N1} 分钟。' -f $it.Iid, $sw.Elapsed.TotalMinutes)
    }
    else {
        Write-Warning ('#{0} 失败 (exit={1})，不记入 state，下次会重试。' -f $it.Iid, $code)
    }
}

# ---------------------------------------------------------------- 汇总

$state | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $statePath -Encoding UTF8

$reports = @(Get-ChildItem -LiteralPath $dayDir -Filter 'mr-*.md' -File |
    Sort-Object { [int]($_.BaseName -replace '\D', '') })

$idx = New-Object System.Text.StringBuilder
$null = $idx.AppendLine('# AI 评审结果 — ' + (Get-Date -Format 'yyyy-MM-dd'))
$null = $idx.AppendLine()
$null = $idx.AppendLine('读取建议：**先看每条的「结论」和「必须改」，其余段落扫一眼就行。**')
$null = $idx.AppendLine('「我不确定的地方」这一节是人必须亲自判断的，AI 帮不了你。')
$null = $idx.AppendLine()

if ($reports.Count -eq 0) {
    $null = $idx.AppendLine('（本次没有产出报告）')
}
foreach ($r in $reports) {
    $txt = [System.IO.File]::ReadAllText($r.FullName, [System.Text.Encoding]::UTF8)
    $verdict = '（未解析到结论段）'
    # 只取「## 结论」下面那一行，不要把后续章节一起吞进来
    $vm = [regex]::Match($txt, '##\s*结论[^\r\n]*\r?\n+([^\r\n]+)')
    if ($vm.Success) { $verdict = $vm.Groups[1].Value.Trim().TrimStart('-', ' ', '：').Trim() }
    $null = $idx.AppendLine(('## [{0}]({0})' -f $r.Name))
    $null = $idx.AppendLine()
    $null = $idx.AppendLine(('**结论**：{0}' -f $verdict))
    $null = $idx.AppendLine()
}

$idxPath = Join-Path $dayDir 'index.md'
Write-Utf8 -Path $idxPath -Text $idx.ToString()

Write-Host ''
Write-Host '完成。早上从这里开始读：' -ForegroundColor Green
Write-Host ('    {0}' -f $idxPath)
