<#
    scan.ps1 — READ-ONLY. Measures every bucket, writes plan.json, prints a
    markdown report table. Never deletes anything.

    Usage:
      scan.ps1                         # quick: auto-safe buckets only
      scan.ps1 -Mode full              # all buckets incl. review/report
      scan.ps1 -Mode deep              # full + node_modules across the profile
      scan.ps1 -Bucket downloads       # a single bucket
      scan.ps1 -Mode full -Out plan.json

    plan.json is the artifact clean.ps1 consumes. It also records driveBefore so
    reclaimed space can be reported as a real measurement, not an estimate.
#>
[CmdletBinding()]
param(
    [ValidateSet('quick', 'full', 'deep')]
    [string]$Mode = 'quick',
    [string]$Bucket,
    [string]$Out = (Join-Path $PSScriptRoot 'plan.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'buckets.ps1')

$floor = $Global:CleanupThresholds.ReportFloorBytes

function Get-DriveState {
    $d = Get-PSDrive C
    [pscustomobject]@{
        usedGB = [math]::Round($d.Used / 1GB, 1)
        freeGB = [math]::Round($d.Free / 1GB, 1)
    }
}

function Measure-FilesBucket {
    param($bucket, [switch]$IncludeItems)
    $items = @()
    $total = 0

    if ($bucket.ContainsKey('DirectoryLevel') -and $bucket.DirectoryLevel) {
        # node_modules: find dirs whose PARENT project is stale, size each dir.
        $cutoff = (Get-Date).AddDays(-$Global:CleanupThresholds.StaleModulesDays)
        foreach ($root in $bucket.Roots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -Attributes !ReparsePoint `
                -Filter 'node_modules' -Depth 6 -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $parent = Split-Path $_.FullName -Parent
                    $parentInfo = Get-Item -LiteralPath $parent -ErrorAction SilentlyContinue
                    if ($parentInfo -and $parentInfo.LastWriteTime -lt $cutoff) {
                        $bytes = Get-FolderBytes $_.FullName
                        if ($bytes -gt 0) {
                            $total += $bytes
                            if ($IncludeItems) {
                                $items += [pscustomobject]@{ path = $_.FullName; bytes = $bytes; lastWrite = $parentInfo.LastWriteTime.ToString('o') }
                            }
                        }
                    }
                }
        }
        return @{ bytes = $total; items = $items }
    }

    $maxDepth = if ($bucket.ContainsKey('MaxDepth')) { $bucket.MaxDepth } else { $null }
    foreach ($root in $bucket.Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $gci = @{ LiteralPath = $root; File = $true; Force = $true; Recurse = $true
                  Attributes = '!ReparsePoint'; ErrorAction = 'SilentlyContinue' }
        if ($null -ne $maxDepth) { $gci.Depth = $maxDepth }
        Get-ChildItem @gci | ForEach-Object {
            $f = $_
            if (& $bucket.Filter $f) {
                $total += $f.Length
                if ($IncludeItems) {
                    $items += [pscustomobject]@{ path = $f.FullName; bytes = $f.Length; lastWrite = $f.LastWriteTime.ToString('o') }
                }
            }
        }
    }
    return @{ bytes = $total; items = $items }
}

function Measure-Bucket {
    param($bucket)
    switch ($bucket.kind) {
        'files'   { return Measure-FilesBucket $bucket -IncludeItems }
        default   { # command | report
            $bytes = 0
            try { $bytes = [int64](& $bucket.Measure) } catch { $bytes = 0 }
            return @{ bytes = $bytes; items = @() }
        }
    }
}

# ---- select which buckets to scan -------------------------------------
$all = Get-CleanupBuckets
if ($Bucket) {
    $selected = $all | Where-Object { $_.id -eq $Bucket }
    if (-not $selected) { throw "Unknown bucket '$Bucket'. Known: $($all.id -join ', ')" }
} else {
    switch ($Mode) {
        'quick' { $selected = $all | Where-Object { $_.safety -eq 'auto' -and $_.kind -ne 'report' } }
        'full'  { $selected = $all | Where-Object { $_.id -ne 'node_modules' } }
        'deep'  { $selected = $all }
    }
}

# ---- measure ----------------------------------------------------------
$driveBefore = Get-DriveState
$reportBuckets = @()
foreach ($b in $selected) {
    $result = Measure-Bucket $b
    if ($result.bytes -lt $floor) { continue }   # skip noise
    $reportBuckets += [pscustomobject]@{
        id        = $b.id
        label     = $b.label
        bytes     = [int64]$result.bytes
        safety    = $b.safety
        undoable  = [bool]$b.undoable
        needsAdmin = [bool]$b.needsAdmin
        kind      = $b.kind
        advice    = if ($b.ContainsKey('Advice')) { $b.Advice } else { $null }
        requiresClosed = if ($b.ContainsKey('RequiresClosed')) { $b.RequiresClosed } else { @() }
        items     = $result.items
    }
}

$plan = [pscustomobject]@{
    generated   = (Get-Date).ToString('o')
    mode        = $Mode
    driveBefore = $driveBefore
    buckets     = $reportBuckets
}
$plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Out -Encoding UTF8

# ---- markdown report --------------------------------------------------
function Format-Size([int64]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } else { '{0:N0} MB' -f ($b / 1MB) }
}
$deletableBytes = ($reportBuckets | Where-Object { $_.kind -ne 'report' } | Measure-Object bytes -Sum).Sum
$reportOnlyBytes = ($reportBuckets | Where-Object { $_.kind -eq 'report' } | Measure-Object bytes -Sum).Sum
if (-not $deletableBytes) { $deletableBytes = 0 }
if (-not $reportOnlyBytes) { $reportOnlyBytes = 0 }

Write-Output ""
Write-Output "| Bucket | Size | Safe? | Undo | Action |"
Write-Output "| --- | --- | --- | --- | --- |"
foreach ($b in ($reportBuckets | Sort-Object bytes -Descending)) {
    $safe = if ($b.safety -eq 'auto') { 'Safe' } else { 'Review' }
    $undo = if ($b.kind -eq 'report') { 'n/a' } elseif ($b.undoable) { 'quarantine' } else { 'permanent' }
    $action = switch ($b.kind) {
        'report'  { 'Report only — hand command to user' }
        default   {
            if ($b.requiresClosed) { "Clear after closing $($b.requiresClosed -join '/')" }
            elseif ($b.safety -eq 'review') { 'List items, you pick' }
            else { 'Clear on OK' }
        }
    }
    Write-Output ("| {0} | {1} | {2} | {3} | {4} |" -f $b.label, (Format-Size $b.bytes), $safe, $undo, $action)
}
Write-Output ""
Write-Output ("Free before: {0} GB. Clearable now: ~{1}." -f $driveBefore.freeGB, (Format-Size $deletableBytes))
if ($reportOnlyBytes -gt 0) {
    Write-Output ("Report-only (compaction/admin, not deleted here): ~{0} — see the 'Report only' rows." -f (Format-Size $reportOnlyBytes))
}
Write-Output ("Plan written to {0}." -f $Out)
Write-Output "Which buckets should I clear? (permanent buckets cannot be undone)"
