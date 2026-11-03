<#
.SYNOPSIS
    从任务队列取任务，交给 traecli 在隔离 worktree 里实现，产出分支 + 报告。

.DESCRIPTION
    这是「AI 实现需求」那一环，和 night-review.ps1（验证环）是配套的。

    和你可能想象的不一样，这个脚本**不拉 issue、不建 PR**。原因：
      - 拉 issue 需要 API token；任务书文件是更好的接口，而且写它的过程本身就是
        任务分解，这一步的技术含量比自动化高得多。
      - 建 PR 需要推送凭证。脚本只产出本地分支，推不推由你决定。

    安全边界（重要）：
      - 永远在**新建的 worktree** 里跑，不碰你的主工作区
      - 永远**不推送**，只产出本地分支
      - 沙箱是 workspace-write，agent 能改代码，但 git 提交由本脚本在沙箱外做
      - 每个任务跑完就归档，不会因为脚本挂掉而重复消耗

.PARAMETER Queue
    任务书目录。默认 %USERPROFILE%\ai-tasks\queue

.PARAMETER Check
    验收命令。agent 必须让它通过，脚本也会独立再跑一遍。默认 `mvn -q test`

.PARAMETER MaxTasks
    本次最多处理几个任务。默认 1 —— 先一次一个，跑顺了再加。

.EXAMPLE
    # 先看看队列里有什么，不执行
    .\dispatch.ps1 -Repo D:\work\myproject -DryRun

.EXAMPLE
    # 正式跑一个
    .\dispatch.ps1 -Repo D:\work\myproject -Base origin/master -Check "mvn -q -pl order-service -am test"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Base = 'origin/main',
    [string]$Root = (Join-Path $env:USERPROFILE 'ai-tasks'),
    [string]$Check = 'mvn -q test',
    [int]$MaxTasks = 1,
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
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
}

function Read-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

# ---------------------------------------------------------------- 前置

$repoRoot = (@(& git -C $Repo rev-parse --show-toplevel 2>$null) -join '').Trim()
if (-not $repoRoot) { throw ("不是 git 仓库：{0}" -f $Repo) }
$repoName = Split-Path $repoRoot -Leaf

$queueDir = Join-Path $Root 'queue'
$doneDir = Join-Path $Root 'done'
$failDir = Join-Path $Root 'failed'
$wtDir = Join-Path $Root 'wt'
$repDir = Join-Path $Root 'reports'
foreach ($d in @($queueDir, $doneDir, $failDir, $wtDir, $repDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$templatePath = Join-Path $PSScriptRoot 'prompts\implement-task.md'
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw ("找不到提示词模板：{0}" -f $templatePath)
}
$template = Read-File $templatePath

# 远端基线要先存在，否则 worktree 建出来是空的还查不出原因
& git -C $repoRoot rev-parse --verify --quiet $Base 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw ("基线分支不存在：{0}。先 git fetch，或用 -Base 指定正确分支。" -f $Base)
}

$tasks = @(Get-ChildItem -LiteralPath $queueDir -Filter '*.md' -File | Sort-Object Name | Select-Object -First $MaxTasks)

if ($tasks.Count -eq 0) {
    Write-Step ("队列是空的：{0}" -f $queueDir)
    Write-Host '放一个任务书进去（格式见 tasks\example-task.md），再跑一次。' -ForegroundColor DarkGray
    return
}

Write-Step ("队列 {0} 个任务，本次处理 {1} 个。验收命令：{2}" -f @(Get-ChildItem -LiteralPath $queueDir -Filter '*.md').Count, $tasks.Count, $Check)

if ($DryRun) {
    Write-Host ''
    Write-Host 'DryRun —— 将处理：' -ForegroundColor Yellow
    foreach ($t in $tasks) {
        Write-Host ('    {0,-40} -> 分支 ai/{1}' -f $t.Name, $t.BaseName)
    }
    Write-Host ''
    Write-Host ('工作树会建在：{0}' -f $wtDir) -ForegroundColor DarkGray
    Write-Host ('agent 命令形态：traecli exec --sandbox workspace-write --ask-for-approval never -C <worktree> -o <报告> -') -ForegroundColor DarkGray
    return
}

if (-not (Get-Command traecli -ErrorAction SilentlyContinue)) {
    throw '找不到 traecli 命令。先在终端确认 `traecli --version` 能跑。'
}

# ---------------------------------------------------------------- 逐个执行

$today = Get-Date -Format 'yyyy-MM-dd'
$dayRep = Join-Path $repDir $today
if (-not (Test-Path -LiteralPath $dayRep)) { New-Item -ItemType Directory -Path $dayRep -Force | Out-Null }

$results = New-Object System.Collections.Generic.List[object]

foreach ($task in $tasks) {
    $id = $task.BaseName
    $branch = 'ai/' + $id
    $wtPath = Join-Path $wtDir ('{0}-{1}' -f $repoName, $id)
    $agentOut = Join-Path $dayRep ('{0}-agent.md' -f $id)
    $reportPath = Join-Path $dayRep ('{0}.md' -f $id)

    Write-Step ('=== {0} ===' -f $id)

    if (Test-Path -LiteralPath $wtPath) {
        Write-Warning ('工作树已存在，跳过：{0}（先删掉或换个任务号）' -f $wtPath)
        continue
    }

    $existingBranch = (@(& git -C $repoRoot branch --list $branch 2>$null) -join '').Trim()
    if ($existingBranch) {
        Write-Warning ('分支已存在，跳过：{0}' -f $branch)
        continue
    }

    Write-Step '创建隔离工作树 ...'
    & git -C $repoRoot worktree add --quiet $wtPath -b $branch $Base
    if ($LASTEXITCODE -ne 0) {
        Write-Warning '创建工作树失败，跳过。'
        continue
    }

    $taskBody = Read-File $task.FullName
    $prompt = $template.
        Replace('{{TASK_ID}}', $id).
        Replace('{{BASE}}', $Base).
        Replace('{{CHECK}}', $Check).
        Replace('{{TASK}}', $taskBody)

    $promptFile = Join-Path $env:TEMP ('ai-task-{0}.md' -f $id)
    Write-Utf8 -Path $promptFile -Text $prompt

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Step 'Agent 执行中，可能要 1~3 小时。发起后请离开，不要盯。'
    $cliArgs = @(
        'exec',
        '--sandbox', 'workspace-write',
        '--ask-for-approval', 'never',
        '--ephemeral',
        '-C', $wtPath,
        '-o', $agentOut,
        '-'
    )
    if ($Model) { $cliArgs += @('-m', $Model) }

    Get-Content -LiteralPath $promptFile -Raw -Encoding UTF8 | & traecli @cliArgs
    $agentCode = $LASTEXITCODE
    $sw.Stop()
    Write-Step ('Agent 结束，退出码 {0}，耗时 {1:N0} 分钟。' -f $agentCode, $sw.Elapsed.TotalMinutes)

    # 独立复验：不相信 agent 自己说跑过了，脚本自己再跑一遍
    Write-Step ('独立复验：{0}' -f $Check)
    Push-Location $wtPath
    $checkOut = & cmd /c "$Check 2>&1" | Out-String
    $checkCode = $LASTEXITCODE
    Pop-Location
    if ($checkCode -eq 0) { Write-Step '验收通过。' } else { Write-Warning ('验收失败，退出码 {0}。' -f $checkCode) }

    # 不管成没成，有改动就提交到本地分支，方便你 git diff 检查
    $committed = $false
    & git -C $wtPath add -A 2>&1 | Out-Null
    $dirty = (@(& git -C $wtPath status --porcelain 2>$null) -join '').Trim()
    if ($dirty) {
        & git -C $wtPath -c user.name='ai-agent' -c user.email='ai-agent@localhost' commit -q -m ("ai({0}): {1}" -f $id, 'overnight implementation') 2>&1 | Out-Null
        $committed = $true
    }

    $diffStat = (@(& git -C $wtPath diff --stat $Base 2>$null) -join '').Trim()
    $ok = ($agentCode -eq 0) -and ($checkCode -eq 0) -and $committed

    # ------------------------------------------------------------ 报告
    $rb = New-Object System.Text.StringBuilder
    $null = $rb.AppendLine(('# {0}' -f $id))
    $null = $rb.AppendLine()
    $null = $rb.AppendLine(('| 项 | 结果 |'))
    $null = $rb.AppendLine(('|---|---|'))
    $null = $rb.AppendLine(('| 状态 | {0} |' -f $(if ($ok) { '**通过**' } else { '**未通过**' })))
    $null = $rb.AppendLine(('| Agent 退出码 | {0} |' -f $agentCode))
    $null = $rb.AppendLine(('| 验收命令 | `{0}` |' -f $Check))
    $null = $rb.AppendLine(('| 验收结果 | {0} |' -f $(if ($checkCode -eq 0) { '通过' } else { "失败（exit $checkCode）" })))
    $null = $rb.AppendLine(('| 是否有提交 | {0} |' -f $(if ($committed) { '是' } else { '否' })))
    $null = $rb.AppendLine(('| 分支 | `{0}` |' -f $branch))
    $null = $rb.AppendLine(('| 工作树 | `{0}` |' -f $wtPath))
    $null = $rb.AppendLine(('| 耗时 | {0:N0} 分钟 |' -f $sw.Elapsed.TotalMinutes))
    $null = $rb.AppendLine()
    $null = $rb.AppendLine('## 改动')
    $null = $rb.AppendLine()
    $null = $rb.AppendLine('```')
    $null = $rb.AppendLine($(if ($diffStat.Trim()) { $diffStat.Trim() } else { '(没有改动)' }))
    $null = $rb.AppendLine('```')
    $null = $rb.AppendLine()
    if ($checkCode -ne 0) {
        $null = $rb.AppendLine('## 验收输出（末尾 40 行）')
        $null = $rb.AppendLine()
        $null = $rb.AppendLine('```')
        $lines = @($checkOut -split "`r?`n")
        $tail = $lines | Select-Object -Last 40
        foreach ($l in $tail) { $null = $rb.AppendLine($l) }
        $null = $rb.AppendLine('```')
        $null = $rb.AppendLine()
    }
    $null = $rb.AppendLine('## Agent 自述')
    $null = $rb.AppendLine()
    $agentText = Read-File $agentOut
    if ($agentText.Trim()) { $null = $rb.AppendLine($agentText.Trim()) }
    else { $null = $rb.AppendLine('（agent 没有产出最终报告）') }
    $null = $rb.AppendLine()
    $null = $rb.AppendLine('---')
    $null = $rb.AppendLine()
    $null = $rb.AppendLine('## 怎么检查')
    $null = $rb.AppendLine()
    $null = $rb.AppendLine('```')
    $null = $rb.AppendLine(('git -C "{0}" log --oneline -3' -f $wtPath))
    $null = $rb.AppendLine(('git -C "{0}" diff {1}' -f $wtPath, $Base))
    $null = $rb.AppendLine('```')
    $null = $rb.AppendLine()
    $null = $rb.AppendLine('**这个分支没有推送。** 确认没问题后自己推：')
    $null = $rb.AppendLine()
    $null = $rb.AppendLine('```')
    $null = $rb.AppendLine(('git -C "{0}" push -u origin {1}' -f $wtPath, $branch))
    $null = $rb.AppendLine('```')

    Write-Utf8 -Path $reportPath -Text $rb.ToString()

    $destDir = if ($ok) { $doneDir } else { $failDir }
    Move-Item -LiteralPath $task.FullName -Destination (Join-Path $destDir $task.Name) -Force

    $results.Add([pscustomobject]@{
        Id      = $id
        Status  = $(if ($ok) { '通过' } else { '未通过' })
        Minutes = [int]$sw.Elapsed.TotalMinutes
        Report  = $reportPath
    })
}

# ---------------------------------------------------------------- 汇总

Write-Host ''
Write-Host '================ 本次结果 ================' -ForegroundColor Green
$results | Format-Table -AutoSize @(
    @{ L = '任务'; E = { $_.Id } },
    @{ L = '状态'; E = { $_.Status } },
    @{ L = '耗时(分)'; E = { $_.Minutes } }
) | Out-String | Write-Host

Write-Host '报告：' -ForegroundColor Green
foreach ($r in $results) { Write-Host ('    ' + $r.Report) }

Write-Host ''
Write-Host '提醒：' -ForegroundColor Yellow
Write-Host '  1. 所有分支都只在本地，没有推送。'
Write-Host '  2. 工作树保留着，检查完用 `wt.ps1 rm <id>` 回收。'
Write-Host '  3. 未通过的任务在 failed\ 里，想重试就把它移回 queue\ ——但先读报告，'
Write-Host '     多数失败是任务书写得不够具体，而不是 AI 不行。'
