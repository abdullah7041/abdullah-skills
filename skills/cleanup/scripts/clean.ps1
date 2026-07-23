<#
    clean.ps1 — the ONLY script that removes anything. Consumes an approved
    plan.json and clears only the buckets named in -Buckets.

    Usage:
      clean.ps1 -Plan plan.json -Buckets temp,devcache
      clean.ps1 -Plan plan.json -Buckets temp -WhatIf   # show, touch nothing

    Safety model:
      * Allowlist gate — every file path is re-validated against the bucket's
        roots from buckets.ps1 (NOT from plan.json) and rejected if it falls
        under a deny root (Documents, Desktop, OneDrive, ...). One bad path
        aborts the whole bucket.
      * Quarantine — undoable 'files' buckets are MOVED to
        %LOCALAPPDATA%\cleanup-quarantine\<timestamp>\ with a manifest.json,
        not deleted. restore.ps1 puts them back. Entries older than 7 days are
        purged at start.
      * Permanent buckets (Recycle Bin, package caches) run their fixed command;
        there is no undo and the script says so.
      * report-kind buckets are refused here — they are advice only.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$Plan,
    [Parameter(Mandatory)][string[]]$Buckets,
    # The specific item paths the user picked. REQUIRED for 'review' buckets
    # (downloads, node_modules) — those are never cleared wholesale.
    [string[]]$Paths,
    [int]$QuarantineRetentionDays = 7
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'buckets.ps1')

if (-not (Test-Path -LiteralPath $Plan)) { throw "Plan not found: $Plan" }
$planData = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json
$registry = Get-CleanupBuckets

$quarantineBase = Join-Path $env:LOCALAPPDATA 'cleanup-quarantine'

function Test-UnderRoot {
    param([string]$Path, [string[]]$Roots)
    $full = try { [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($r in $Roots) {
        if (-not $r) { continue }
        $rf = try { [System.IO.Path]::GetFullPath($r) } catch { continue }
        $rf = $rf.TrimEnd('\')
        if ($full.Equals($rf, 'OrdinalIgnoreCase') -or
            $full.StartsWith($rf + '\', 'OrdinalIgnoreCase')) { return $true }
    }
    return $false
}

function Test-PathAllowed {
    param([string]$Path, [string[]]$AllowRoots)
    if (-not (Test-UnderRoot -Path $Path -Roots $AllowRoots)) { return $false }
    if (Test-UnderRoot -Path $Path -Roots $Global:CleanupDenyRoots) { return $false }
    return $true
}

function Get-Norm { param([string]$p) try { [System.IO.Path]::GetFullPath($p).TrimEnd('\').ToLowerInvariant() } catch { $p.ToLowerInvariant() } }

function Get-ItemBytes {
    param([string]$Path)
    $it = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $it) { return 0 }
    if ($it.PSIsContainer) { return (Get-FolderBytes $Path) }
    return $it.Length
}

# Build the user's pick set once (normalized), if -Paths was given.
$pickSet = $null
if ($Paths) { $pickSet = @{}; $Paths | ForEach-Object { $pickSet[(Get-Norm $_)] = $true } }

$quarantineVolume = (Split-Path $quarantineBase -Qualifier)

# ---- purge stale quarantine entries -----------------------------------
if (Test-Path -LiteralPath $quarantineBase) {
    $cutoff = (Get-Date).AddDays(-$QuarantineRetentionDays)
    Get-ChildItem -LiteralPath $quarantineBase -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -lt $cutoff } |
        ForEach-Object {
            Write-Host "Purging expired quarantine: $($_.Name)"
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$quarantineDir = Join-Path $quarantineBase $stamp
$totalFreed = 0
$qCounter = 0   # unique per-run index so quarantined leaf names never collide

foreach ($id in $Buckets) {
    $planBucket = $planData.buckets | Where-Object { $_.id -eq $id }
    $regBucket  = $registry | Where-Object { $_.id -eq $id }
    if (-not $regBucket) { Write-Warning "Unknown bucket '$id' — skipped."; continue }
    if (-not $planBucket) { Write-Warning "Bucket '$id' not in plan (nothing scanned) — skipped."; continue }

    if ($regBucket.kind -eq 'report') {
        Write-Warning "Bucket '$id' is report-only. Not cleared. Advice: $($regBucket.Advice)"
        continue
    }

    # Guard: browser buckets require the browser closed.
    if ($regBucket.ContainsKey('RequiresClosed')) {
        $running = @()
        foreach ($proc in $regBucket.RequiresClosed) {
            if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { $running += $proc }
        }
        if ($running) {
            Write-Warning "Bucket '$id' needs these closed first: $($running -join ', '). Skipped."
            continue
        }
    }

    if (-not $regBucket.undoable) {
        Write-Host "[$id] PERMANENT — no undo. $($regBucket.label)"
        if ($PSCmdlet.ShouldProcess($regBucket.label, 'run permanent cleanup command')) {
            try { & $regBucket.Clean } catch { Write-Warning "[$id] command failed: $_" }
        }
        continue
    }

    # ---- undoable 'files' bucket: validate, then quarantine-move -------
    $items = @($planBucket.items)
    if (-not $items.Count) { Write-Host "[$id] no items in plan — skipped."; continue }

    # Review buckets are never cleared wholesale — the user must pick items.
    if ($regBucket.safety -eq 'review') {
        if (-not $pickSet) {
            Write-Warning "[$id] is a review bucket. Pass -Paths with the exact files the user picked; it is never cleared wholesale. Nothing touched."
            continue
        }
        $items = @($items | Where-Object { $pickSet.ContainsKey((Get-Norm $_.path)) })
        if (-not $items.Count) { Write-Warning "[$id] none of -Paths matched this bucket's plan items. Skipped."; continue }
    } elseif ($pickSet) {
        # -Paths also narrows auto buckets when supplied.
        $items = @($items | Where-Object { $pickSet.ContainsKey((Get-Norm $_.path)) })
        if (-not $items.Count) { Write-Warning "[$id] none of -Paths matched this bucket's plan items. Skipped."; continue }
    }

    $rejected = @($items | Where-Object { -not (Test-PathAllowed -Path $_.path -AllowRoots $regBucket.Roots) })
    if ($rejected) {
        Write-Warning "[$id] ABORTED — $($rejected.Count) path(s) outside the allowlist or under a protected folder:"
        $rejected | ForEach-Object { Write-Warning "    $($_.path)" }
        Write-Warning "[$id] No files in this bucket were touched."
        continue
    }

    New-Item -ItemType Directory -Force -Path $quarantineDir | Out-Null
    $bucketFreed = 0
    foreach ($item in $items) {
        $src = $item.path
        if (-not (Test-Path -LiteralPath $src)) { continue }

        # Cross-volume moves would copy gigabytes (and can fill the target).
        # A same-volume move is a near-instant rename. Refuse cross-volume here.
        if ((Split-Path $src -Qualifier) -ne $quarantineVolume) {
            Write-Warning "[$id] $src is on a different volume than quarantine ($quarantineVolume). Skipped — needs explicit hard-delete confirmation, not a silent multi-GB copy."
            continue
        }

        if ($PSCmdlet.ShouldProcess($src, 'quarantine (move)')) {
            try {
                # Flat layout: <stamp>\<counter>_<leaf>. Avoids doubling path
                # depth (which overruns 260 chars on PS 5.1 for deep caches).
                $qCounter++
                $leaf = Split-Path $src -Leaf
                $dest = Join-Path $quarantineDir ('{0:D5}_{1}' -f $qCounter, $leaf)
                $size = Get-ItemBytes $src
                Move-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
                Add-Content -LiteralPath (Join-Path $quarantineDir 'manifest.json') `
                    -Value (([pscustomobject]@{ bucket = $id; original = $src; quarantined = $dest; bytes = $size } | ConvertTo-Json -Compress))
                $bucketFreed += $size
            } catch {
                Write-Warning "[$id] could not move $src : $_"
            }
        }
    }
    $totalFreed += $bucketFreed
    Write-Host ("[$id] quarantined {0:N1} MB (restorable for $QuarantineRetentionDays days)" -f ($bucketFreed / 1MB))
}

# ---- measured result --------------------------------------------------
if (-not $WhatIfPreference) {
    $after = Get-PSDrive C
    Write-Host ""
    Write-Host ("Free before: {0} GB  ->  after: {1} GB" -f $planData.driveBefore.freeGB, [math]::Round($after.Free / 1GB, 1))
    if ($totalFreed) { Write-Host ("Quarantined this run: {0:N1} MB" -f ($totalFreed / 1MB)) }
    if (Test-Path -LiteralPath $quarantineDir) {
        Write-Host "Undo with: restore.ps1 -Manifest `"$(Join-Path $quarantineDir 'manifest.json')`""
    }
}
