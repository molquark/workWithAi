<#
.SYNOPSIS
    扫描 Maven 多模块 Java 仓库，生成 AI 和人共用的「项目地图」与「工具类清单」。

.DESCRIPTION
    解决一个具体问题：本仓库没有统一的 common 包，工具类散落在 biz.*.util 和各
    service 模块里。人工维护清单必然过期，而过期的清单比没有清单更糟——AI 会
    照着错的清单去找，然后放弃并新建一个。

    所以这份清单是**生成**的，不是**维护**的。每次大改动后重跑一遍即可。

    输出：
      docs/PROJECT_MAP.md  模块、包分布、分层统计、关键类型全限定名
      docs/UTILITIES.md    所有工具类及其公开方法，重名类会被标出来

.PARAMETER Repo
    仓库根目录（含根 pom.xml 的目录）。默认当前目录。

.PARAMETER OutDir
    输出目录，相对仓库根。默认 docs。

.PARAMETER KeyTypes
    需要在地图里定位的关键类型简单名。找不到时会明确提示。

.EXAMPLE
    pwsh -File scripts/scan-conventions.ps1 -Repo D:\work\myproject
#>
[CmdletBinding()]
param(
    [string]$Repo = '.',
    [string]$OutDir = 'docs',
    [string[]]$KeyTypes = @('Result', 'Tuple', 'UserHolder')
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 工具函数

function Get-RelPath {
    param([string]$Base, [string]$Full)
    if ($Full.StartsWith($Base, [System.StringComparison]::OrdinalIgnoreCase)) {
        $r = $Full.Substring($Base.Length)
        $r = $r.TrimStart([char]'\', [char]'/')
        if ([string]::IsNullOrEmpty($r)) { return '.' }
        return ($r -replace '\\', '/')
    }
    return ($Full -replace '\\', '/')
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $enc = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-PublicSignatures {
    param([string]$Text, [string]$ClassName)
    $result = New-Object System.Collections.Generic.List[string]
    $rx = [regex]'(?m)^[ \t]*public\s+([^;{=]*?\([^)]*\))'
    foreach ($m in $rx.Matches($Text)) {
        $sig = ($m.Groups[1].Value -replace '\s+', ' ').Trim()
        if ($sig.Length -gt 200) { continue }
        # 排除类/接口/枚举/注解声明，以及构造器
        if ($sig -match '^(class|interface|enum|record|abstract class|final class|@)') { continue }
        if ($sig -match "[\.\s]$ClassName\s*\(") { continue }
        if ([string]::IsNullOrWhiteSpace($sig)) { continue }
        $sig = $sig -replace '\s*\(\s*', '(' -replace '\s*\)', ')' -replace ',\s*', ', '
        $result.Add($sig)
    }
    return $result
}

function Get-ClassDoc {
    param([string]$Text, [string]$ClassName)
    $rx = [regex]("(?s)/\*\*(.*?)\*/\s*(?:@\w+(?:\([^\)]*\))?\s*)*(?:public\s+|final\s+|abstract\s+)*(?:class|interface|enum|record)\s+" + [regex]::Escape($ClassName) + "\b")
    $m = $rx.Match($Text)
    if (-not $m.Success) { return $null }
    foreach ($line in [regex]::Split($m.Groups[1].Value, "\r?\n")) {
        $t = ($line -replace '^\s*\*+', '').Trim()
        if ($t -and $t -notmatch '^@') { return $t }
    }
    return $null
}

# ---------------------------------------------------------------- 采集

$repoRoot = (Resolve-Path -LiteralPath $Repo).Path
$outAbs = Join-Path $repoRoot $OutDir
if (-not (Test-Path -LiteralPath $outAbs)) {
    New-Item -ItemType Directory -Path $outAbs -Force | Out-Null
}

Write-Host "[1/4] 查找 Maven 模块 ..." -ForegroundColor Cyan
$poms = @(Get-ChildItem -LiteralPath $repoRoot -Filter 'pom.xml' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '[\\/]target[\\/]' -and $_.FullName -notmatch '[\\/]\.git[\\/]' })

$modules = @()
foreach ($p in $poms) {
    $rel = Get-RelPath -Base $repoRoot -Full $p.DirectoryName
    $modules += [pscustomobject]@{ Path = $rel; FullPath = $p.DirectoryName }
}

Write-Host "[2/4] 解析 Java 源文件 ..." -ForegroundColor Cyan
$javaFiles = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.java' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '[\\/]src[\\/]main[\\/]java[\\/]' })

if ($javaFiles.Count -eq 0) {
    Write-Warning "没找到 src/main/java 下的 .java 文件（路径: $repoRoot）。检查一下 -Repo 参数？"
    return
}

$classes = New-Object System.Collections.Generic.List[object]
foreach ($f in $javaFiles) {
    # 必须显式按 UTF-8 读。Windows PowerShell 5.1 的 Get-Content 默认按 ANSI 解，
    # 而 IntelliJ 默认写 UTF-8 无 BOM —— 直接 Get-Content 会把所有中文注释读成乱码。
    $text = $null
    try {
        $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    }
    catch {
        Write-Warning ("跳过（读取失败）：{0}" -f $f.FullName)
        continue
    }
    if ([string]::IsNullOrWhiteSpace($text)) { continue }

    $pm = [regex]::Match($text, '(?m)^[ \t]*package[ \t]+([A-Za-z_][\w\.]*)[ \t]*;')
    $pkg = if ($pm.Success) { $pm.Groups[1].Value } else { '(default)' }

    $module = '(root)'
    if ($f.FullName -match '^(.*?)[\\/]src[\\/]main[\\/]java[\\/]') {
        $module = Get-RelPath -Base $repoRoot -Full $Matches[1]
        if ($module -eq '.') { $module = '(root)' }
    }

    $classes.Add([pscustomobject]@{
        Name    = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        Package = $pkg
        Module  = $module
        RelPath = Get-RelPath -Base $repoRoot -Full $f.FullName
        Text    = $text
    })
}

Write-Host ("      共 {0} 个类，{1} 个模块。" -f $classes.Count, $modules.Count) -ForegroundColor DarkGray

# ---------------------------------------------------------------- 归类

$layerKeys = @(
    'controller', 'service', 'mapper', 'dao', 'repository', 'entity', 'domain',
    'dto', 'vo', 'bo', 'po', 'param', 'request', 'response', 'config', 'util',
    'utils', 'handler', 'exception', 'feign', 'client', 'job', 'task', 'aspect',
    'interceptor', 'filter', 'constant', 'enums', 'convert', 'converter'
)

foreach ($c in $classes) {
    $segs = $c.Package -split '\.'
    $layer = 'other'
    for ($i = $segs.Count - 1; $i -ge 0; $i--) {
        if ($layerKeys -contains $segs[$i]) { $layer = $segs[$i]; break }
    }
    $c | Add-Member -NotePropertyName Layer -NotePropertyValue $layer -Force
}

$utilClasses = @($classes | Where-Object { $_.Name -match '(Util|Utils|Helper|Tool|Tools)$' })

# ---------------------------------------------------------------- PROJECT_MAP.md

Write-Host "[3/4] 生成 PROJECT_MAP.md ..." -ForegroundColor Cyan

$sb = New-Object System.Text.StringBuilder
$now = Get-Date -Format 'yyyy-MM-dd HH:mm'
$null = $sb.AppendLine('# 项目地图')
$null = $sb.AppendLine()
$null = $sb.AppendLine("> 自动生成，请勿手工修改。生成于 $now。")
$null = $sb.AppendLine('> 重新生成：`powershell -ExecutionPolicy Bypass -File scripts\scan-conventions.ps1`')
$null = $sb.AppendLine('>')
$null = $sb.AppendLine('> **给 AI 的提示**：这份文件告诉你代码在哪，不告诉你业务怎么走。')
$null = $sb.AppendLine('> 改代码前先在这里定位，再用 grep 找 2~3 个同类实现照抄结构。')
$null = $sb.AppendLine()

$null = $sb.AppendLine('## 模块')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| 模块路径 | 类文件数 |')
$null = $sb.AppendLine('| --- | ---: |')
foreach ($m in ($modules | Sort-Object Path)) {
    $cnt = 0
    foreach ($c in $classes) {
        if ($c.Module -eq $m.Path -or ($m.Path -eq '(root)' -and $c.Module -eq '(root)')) { $cnt++ }
    }
    $null = $sb.AppendLine(("| ``{0}`` | {1} |" -f $m.Path, $cnt))
}
$null = $sb.AppendLine()

$null = $sb.AppendLine('## 分层分布')
$null = $sb.AppendLine()
$null = $sb.AppendLine('按包名归类。用来判断「这个项目实际长什么样」，以及新代码该放哪。')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| 层 | 类文件数 | 典型包 |')
$null = $sb.AppendLine('| --- | ---: | --- |')
$layerGroups = $classes | Group-Object Layer | Sort-Object Count -Descending
foreach ($g in $layerGroups) {
    $sample = @($g.Group | Select-Object -First 2 -ExpandProperty Package) -join '<br>'
    $null = $sb.AppendLine(("| {0} | {1} | {2} |" -f $g.Name, $g.Count, $sample))
}
$null = $sb.AppendLine()

$null = $sb.AppendLine('## 关键类型位置')
$null = $sb.AppendLine()
$null = $sb.AppendLine('AI 最容易搞错的地方：以为这些是 Spring 自带的，或者找不到就自己新建一个。')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| 类型 | 全限定名 | 文件 |')
$null = $sb.AppendLine('| --- | --- | --- |')
$missing = @()
foreach ($kt in $KeyTypes) {
    $hits = @($classes | Where-Object { $_.Name -eq $kt })
    if ($hits.Count -eq 0) {
        $missing += $kt
        $null = $sb.AppendLine(("| ``{0}`` | **未在本仓库源码中找到** | — |" -f $kt))
    }
    else {
        foreach ($h in $hits) {
            $null = $sb.AppendLine(("| ``{0}`` | ``{1}.{0}`` | {2} |" -f $h.Name, $h.Package, $h.RelPath))
        }
    }
}
$null = $sb.AppendLine()

if ($missing.Count -gt 0) {
    $null = $sb.AppendLine('> ⚠️ **未找到：** ' + ($missing -join '、'))
    $null = $sb.AppendLine('> 可能它在依赖 jar 里（不在本仓库源码中），也可能只是名字不同。')
    $null = $sb.AppendLine('> 请手工在下面补一行，并说明「怎么 import」。这一行对 AI 的价值高于整份文档。')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('```java')
    $null = $sb.AppendLine('// 例如：')
    $null = $sb.AppendLine('// import com.example.common.web.Result;')
    $null = $sb.AppendLine('```')
    $null = $sb.AppendLine()
}

$null = $sb.AppendLine('## 包分布（按类文件数取前 30）')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| 包 | 类文件数 |')
$null = $sb.AppendLine('| --- | ---: |')
$pkgGroups = $classes | Group-Object Package | Sort-Object Count -Descending | Select-Object -First 30
foreach ($g in $pkgGroups) {
    $null = $sb.AppendLine(("| ``{0}`` | {1} |" -f $g.Name, $g.Count))
}
$null = $sb.AppendLine()
$null = $sb.AppendLine(("合计 {0} 个包。" -f ($classes | Group-Object Package).Count))

$mapPath = Join-Path $outAbs 'PROJECT_MAP.md'
Write-Utf8 -Path $mapPath -Text $sb.ToString()

# ---------------------------------------------------------------- UTILITIES.md

Write-Host "[4/4] 生成 UTILITIES.md ..." -ForegroundColor Cyan

$ub = New-Object System.Text.StringBuilder
$null = $ub.AppendLine('# 工具类清单')
$null = $ub.AppendLine()
$null = $ub.AppendLine("> 自动生成，请勿手工修改。生成于 $now。")
$null = $ub.AppendLine('>')
$null = $ub.AppendLine('> **给 AI 的提示**：本仓库的工具类不集中在一个 common 包，散落在各模块。')
$null = $ub.AppendLine('> **写任何 `XxxUtil` / `XxxHelper` 之前，必须先在本文件中查一遍。**')
$null = $ub.AppendLine('> 找到了就复用；找不到，在 PR 描述里提出，不要自己新建。')
$null = $ub.AppendLine()
$null = $ub.AppendLine(("共 {0} 个工具类。" -f $utilClasses.Count))
$null = $ub.AppendLine()

# 重名检测——散乱的直接证据
$dupes = @($utilClasses | Group-Object Name | Where-Object { $_.Count -gt 1 })
if ($dupes.Count -gt 0) {
    $null = $ub.AppendLine('## ⚠️ 重名工具类')
    $null = $ub.AppendLine()
    $null = $ub.AppendLine('同名但不同包。这类冲突最容易让 AI（和人）用错，建议逐步收敛。')
    $null = $ub.AppendLine()
    foreach ($d in $dupes) {
        $null = $ub.AppendLine(("**``{0}``**" -f $d.Name))
        foreach ($c in $d.Group) {
            $null = $ub.AppendLine(("- ``{0}`` — {1}" -f $c.Package, $c.RelPath))
        }
        $null = $ub.AppendLine()
    }
}

$byPkg = $utilClasses | Group-Object Package | Sort-Object Name
foreach ($g in $byPkg) {
    $null = $ub.AppendLine(("## ``{0}``" -f $g.Name))
    $null = $ub.AppendLine()
    foreach ($c in ($g.Group | Sort-Object Name)) {
        $null = $ub.AppendLine(("### {0}" -f $c.Name))
        $null = $ub.AppendLine()
        $doc = Get-ClassDoc -Text $c.Text -ClassName $c.Name
        if ($doc) { $null = $ub.AppendLine(("> {0}" -f $doc)); $null = $ub.AppendLine() }
        $null = $ub.AppendLine(("- 文件：``{0}``" -f $c.RelPath))
        $null = $ub.AppendLine(("- 全限定名：``{0}.{1}``" -f $c.Package, $c.Name))
        $sigs = Get-PublicSignatures -Text $c.Text -ClassName $c.Name
        if ($sigs.Count -gt 0) {
            $null = $ub.AppendLine('- 公开方法：')
            foreach ($s in $sigs) {
                $null = $ub.AppendLine(("    - ``{0}``" -f $s))
            }
        }
        else {
            $null = $ub.AppendLine('- 公开方法：（无）')
        }
        $null = $ub.AppendLine()
    }
}

$utilPath = Join-Path $outAbs 'UTILITIES.md'
Write-Utf8 -Path $utilPath -Text $ub.ToString()

# ---------------------------------------------------------------- 汇总

Write-Host ''
Write-Host '完成：' -ForegroundColor Green
Write-Host ("  {0}" -f $mapPath)
Write-Host ("  {0}" -f $utilPath)
Write-Host ''
Write-Host ("类 {0} 个 / 模块 {1} 个 / 工具类 {2} 个 / 重名 {3} 组" -f `
    $classes.Count, $modules.Count, $utilClasses.Count, $dupes.Count) -ForegroundColor DarkGray

if ($utilClasses.Count -gt 40) {
    Write-Host ''
    Write-Host ("提示：工具类有 {0} 个，偏多。先别急着合并——把 UTILITIES.md 里同名的那几组处理掉，" -f $utilClasses.Count) -ForegroundColor Yellow
    Write-Host '      收益比大扫除高，而且不会撞到别人的代码。' -ForegroundColor Yellow
}
