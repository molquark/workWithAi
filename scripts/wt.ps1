<#
.SYNOPSIS
    工作树管理器。给 worktree 加上强制上限和回收机制。

.DESCRIPTION
    杂乱的根源不是 worktree，是没有上限的 WIP。这个脚本做三件事：
      - new   开一个，命名规整，基于 origin/main
      - ls    列出所有活着的，带「几天没动」和「有没有未提交改动」
      - rm    删掉一个（含分支，已合并才删）
      - clean 批量清理：超过 N 天、无未提交改动、已合入基线分支 → 列出待回收

    ls 会在存活数超过 3 时报警。这个数字不是随便定的：你能同时「有效推进」
    的需求就是 2~3 个，多出来的只会分走注意力。

.PARAMETER Cmd
    new | ls | rm | clean

.PARAMETER Ticket
    需求号或短名，用作工作树目录名和分支名的一部分。

.EXAMPLE
    .\wt.ps1 new PROJ-1024
    .\wt.ps1 ls
    .\wt.ps1 rm PROJ-1024
    .\wt.ps1 clean -StaleDays 7
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('new', 'ls', 'rm', 'clean')]
    [string]$Cmd,

    [Parameter(Position = 1)]
    [string]$Ticket,

    [string]$Repo = '.',
    [string]$Prefix = 'feat',
    [string]$Base = 'origin/main',
    [string]$Root = '',
    [int]$StaleDays = 7,
    [int]$MaxAlive = 3
)

$ErrorActionPreference = 'Stop'

$topRaw = (& git -C $Repo rev-parse --show-toplevel 2>$null)
if (-not $topRaw) { throw ("不是 git 仓库：{0}" -f $Repo) }
$repoRoot = ([string]$topRaw).Trim()
$repoName = Split-Path $repoRoot -Leaf

# 工作树放在仓库的同级目录，不放仓库内部（避免 IDE 把副本当模块扫描）
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Join-Path (Split-Path $repoRoot -Parent) 'wt'
}

function Get-Worktrees {
    $entries = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($line in @(& git -C $repoRoot worktree list --porcelain)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($null -ne $cur) { $entries.Add($cur); $cur = $null }
            continue
        }
        if ($null -eq $cur) { $cur = [ordered]@{} }
        $sp = $line.IndexOf(' ')
        if ($sp -lt 0) { $cur[$line] = '' }
        else { $cur[$line.Substring(0, $sp)] = $line.Substring($sp + 1) }
    }
    if ($null -ne $cur) { $entries.Add($cur) }
    return $entries
}

function Get-WorktreeInfo {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in (Get-Worktrees)) {
        $path = [string]$e['worktree']
        $branch = ''
        if ($e.Contains('branch')) {
            $branch = ([string]$e['branch']) -replace '^refs/heads/', ''
        }
        elseif ($e.Contains('detached')) {
            $branch = '(detached)'
        }

        $days = $null
        if ($branch -and $branch -ne '(detached)') {
            $d = & git -C $repoRoot log -1 --date=short --format=%ad $branch 2>$null
            $parsed = [datetime]::MinValue
            if ($d -and [datetime]::TryParse([string]$d, [ref]$parsed)) {
                $days = [int]((Get-Date).Date - $parsed.Date).TotalDays
            }
        }

        $dirty = 0
        if (Test-Path -LiteralPath $path) {
            $dirty = @(& git -C $path status --porcelain 2>$null | Where-Object { $_ }).Count
        }

        $rows.Add([pscustomobject]@{
            Path   = $path
            Branch = $branch
            Dirty  = $dirty
            Days   = $days
            Exists = (Test-Path -LiteralPath $path)
        })
    }
    return $rows
}

function Resolve-Target {
    param([string]$Key)
    $rows = @(Get-WorktreeInfo)
    $hit = @($rows | Where-Object { $_.Path -like "*$Key*" })
    if ($hit.Count -eq 0) { throw ("找不到匹配 '{0}' 的工作树。先跑 `wt ls` 看看。" -f $Key) }
    if ($hit.Count -gt 1) {
        Write-Host '匹配到多个，请说得更具体：' -ForegroundColor Yellow
        $hit | ForEach-Object { Write-Host ('    ' + $_.Path) }
        throw '匹配不唯一'
    }
    return $hit[0]
}

switch ($Cmd) {

    'new' {
        if ([string]::IsNullOrWhiteSpace($Ticket)) { throw '用法: wt.ps1 new <ticket>' }
        $branch = '{0}/{1}' -f $Prefix, $Ticket
        $path = Join-Path $Root ('{0}-{1}' -f $repoName, $Ticket)

        $alive = @(Get-WorktreeInfo).Count
        if ($alive -ge $MaxAlive) {
            Write-Host ("警告：当前已有 {0} 个工作树（上限 {1}）。" -f $alive, $MaxAlive) -ForegroundColor Yellow
            Write-Host '再开一个之前，先关掉一个。WIP 超限的代价比你想的高。' -ForegroundColor Yellow
            Write-Host ''
        }
        if (Test-Path -LiteralPath $path) { throw ("目录已存在：{0}" -f $path) }

        if (-not (Test-Path -LiteralPath $Root)) {
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
        }

        & git -C $repoRoot fetch origin --quiet
        & git -C $repoRoot worktree add $path -b $branch $Base
        if ($LASTEXITCODE -ne 0) { throw '创建失败' }

        Write-Host ''
        Write-Host ('工作树  {0}' -f $path) -ForegroundColor Green
        Write-Host ('分支    {0}（基于 {1}）' -f $branch, $Base)
        Write-Host '提醒    提 PR 时确认目标分支，通常不是主分支。'
    }

    'ls' {
        $rows = @(Get-WorktreeInfo)
        $rows | Format-Table -AutoSize @(
            @{ L = '工作树'; E = { $_.Path } },
            @{ L = '分支'; E = { $_.Branch } },
            @{ L = '未提交'; E = { $_.Dirty } },
            @{ L = '最后提交(天前)'; E = { if ($null -eq $_.Days) { '-' } else { $_.Days } } }
        ) | Out-String | Write-Host

        if ($rows.Count -gt $MaxAlive) {
            Write-Host ("⚠ 存活 {0} 个，超过上限 {1}。" -f $rows.Count, $MaxAlive) -ForegroundColor Yellow
            Write-Host '  跑 `wt clean` 看哪些可以回收。' -ForegroundColor Yellow
        }
        else {
            Write-Host ("存活 {0} 个（上限 {1}）。" -f $rows.Count, $MaxAlive) -ForegroundColor DarkGray
        }
    }

    'rm' {
        if ([string]::IsNullOrWhiteSpace($Ticket)) { throw '用法: wt.ps1 rm <ticket 或路径片段>' }
        $t = Resolve-Target -Key $Ticket
        if ($t.Branch -eq '(detached)') { throw '这是一个 detached HEAD，脚本不敢动，请手工处理。' }
        if ($t.Dirty -gt 0) {
            Write-Host ("该工作树有 {0} 个未提交改动。" -f $t.Dirty) -ForegroundColor Yellow
            $ans = Read-Host '仍然强制删除？未提交的内容会丢失 (y/N)'
            if ($ans -ne 'y') { Write-Host '已取消。'; return }
        }

        & git -C $repoRoot worktree remove --force $t.Path
        if ($LASTEXITCODE -ne 0) { throw '移除工作树失败' }

        # -d 只在分支已合并时删除；没合并会失败，这是有意的保护
        & git -C $repoRoot branch -d $t.Branch 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ('已删除工作树和分支：{0}' -f $t.Branch) -ForegroundColor Green
        }
        else {
            Write-Host ('工作树已删，但分支 {0} 还没合并，已保留。' -f $t.Branch) -ForegroundColor Yellow
            Write-Host ('确认不要了就手动：git branch -D {0}' -f $t.Branch) -ForegroundColor Yellow
        }
    }

    'clean' {
        $rows = @(Get-WorktreeInfo)
        $main = $rows | Select-Object -First 1
        $candidates = @($rows | Where-Object {
                $_.Path -ne $main.Path -and $_.Exists -and $_.Dirty -eq 0 -and
                $null -ne $_.Days -and $_.Days -ge $StaleDays
            })

        if ($candidates.Count -eq 0) {
            Write-Host ("没有超过 {0} 天且干净的工作树。干净。" -f $StaleDays) -ForegroundColor Green
            return
        }

        Write-Host ("以下 {0} 个工作树超过 {1} 天没动，且没有未提交改动：" -f $candidates.Count, $StaleDays) -ForegroundColor Yellow
        foreach ($c in $candidates) {
            $merged = @(& git -C $repoRoot branch --merged $Base 2>$null | ForEach-Object { $_.Trim() -replace '^\* ', '' })
            $isMerged = $merged -contains $c.Branch
            $tag = if ($isMerged) { '已合入，可删' } else { '未合入，保留' }
            Write-Host ('    {0,-50} {1,-28} {2,3} 天  {3}' -f (Split-Path $c.Path -Leaf), $c.Branch, $c.Days, $tag)
        }

        Write-Host ''
        Write-Host '本脚本不会自动删未合入的分支。确认后逐个跑：wt rm <ticket>' -ForegroundColor DarkGray
    }
}
