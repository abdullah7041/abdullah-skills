<#
    buckets.ps1 — shared bucket registry for the cleanup skill.

    Single source of truth. Both scan.ps1 and clean.ps1 dot-source this file so
    the set of buckets, their allowlisted roots, and their safety flags can
    never drift apart. clean.ps1 re-derives the allowlist from here by id — it
    never trusts roots written into plan.json.

    A bucket is a hashtable with:
      id        unique slug (used on the command line and in plan.json)
      label     human-readable name for the report
      safety    'auto'   -> clearable as a batch on one confirmation
                'review' -> every item must be shown and picked individually
      undoable  $true  -> clean.ps1 quarantines (restorable for 7 days)
                $false -> deletion is permanent; must be stated at confirmation
      needsAdmin whether the operation requires an elevated shell
      kind      'files'   -> enumerate items under Roots, quarantine on clean
                'command' -> run a fixed command (Recycle Bin, package caches)
                'report'  -> measure and advise only; clean.ps1 never touches it
      Roots     (files) absolute directories the bucket is allowed to touch.
                clean.ps1 refuses any item that does not live under one of these.
      Filter    (files) scriptblock: takes a FileInfo, returns $true to include
      Measure   (command/report) scriptblock returning recovered bytes
      Advice    (report) exact command to hand the user; never auto-run
      MinDepth/MaxDepth  (files) optional recursion bounds
#>

Set-StrictMode -Version Latest

# Deny roots: never delete anything under these, whatever a bucket claims.
$Global:CleanupDenyRoots = @(
    [Environment]::GetFolderPath('MyDocuments'),
    [Environment]::GetFolderPath('MyPictures'),
    [Environment]::GetFolderPath('MyVideos'),
    [Environment]::GetFolderPath('MyMusic'),
    [Environment]::GetFolderPath('Desktop'),
    "$env:USERPROFILE\OneDrive",
    "$env:USERPROFILE\Dropbox",
    "$env:OneDrive"
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique

# Age/size thresholds — kept identical to the v1 skill's thresholds table.
$Global:CleanupThresholds = @{
    LargeDownloadBytes = 100MB
    OldFileDays        = 90
    StaleModulesDays   = 60
    ReportFloorBytes   = 50MB
}

function Get-FolderBytes {
    param([string]$Path, [int]$MaxDepth = 0)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    # -Attributes !ReparsePoint skips junctions/symlinks so we don't follow
    # loops or double-count linked content.
    $sum = 0
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force -Attributes !ReparsePoint -ErrorAction SilentlyContinue |
            ForEach-Object { $sum += $_.Length }
    } catch { }
    return $sum
}

function Get-CleanupBuckets {
    $t = $Global:CleanupThresholds
    $buckets = @()

    # ---- files: temp / system junk -------------------------------------
    $buckets += @{
        id = 'temp'; label = 'Temp / system junk'
        safety = 'auto'; undoable = $true; needsAdmin = $false; kind = 'files'
        Roots = @("$env:TEMP", "$env:WINDIR\Temp") | Select-Object -Unique
        Filter = { param($f) $true }
    }

    # ---- files: Downloads (large or old) — per-file review -------------
    $buckets += @{
        id = 'downloads'; label = 'Downloads (large/old)'
        safety = 'review'; undoable = $true; needsAdmin = $false; kind = 'files'
        Roots = @("$env:USERPROFILE\Downloads")
        MaxDepth = 1
        Filter = {
            param($f)
            $f.Length -ge $Global:CleanupThresholds.LargeDownloadBytes -or
            $f.LastWriteTime -lt (Get-Date).AddDays(-$Global:CleanupThresholds.OldFileDays)
        }
    }

    # ---- files: stale node_modules ------------------------------------
    # Enumerated specially in scan.ps1 (directory-level, staleness by parent),
    # but declared here so clean.ps1 knows the allowlist root and safety.
    $buckets += @{
        id = 'node_modules'; label = 'Stale node_modules'
        safety = 'review'; undoable = $true; needsAdmin = $false; kind = 'files'
        Roots = @("$env:USERPROFILE")
        Filter = { param($f) $true }
        DirectoryLevel = $true
    }

    # ---- files: developer caches --------------------------------------
    $devCacheRoots = @(
        "$env:LOCALAPPDATA\npm-cache",
        "$env:APPDATA\npm-cache",
        "$env:LOCALAPPDATA\Yarn\Cache",
        "$env:LOCALAPPDATA\pnpm-cache",
        "$env:LOCALAPPDATA\pip\Cache",
        "$env:USERPROFILE\.cargo\registry\cache",
        "$env:USERPROFILE\go\pkg\mod\cache\download",
        "$env:USERPROFILE\.gradle\caches",
        "$env:USERPROFILE\.m2\repository",
        "$env:USERPROFILE\.nuget\packages",
        "$env:LOCALAPPDATA\uv\cache",
        "$env:LOCALAPPDATA\pypoetry\Cache",
        "$env:APPDATA\Code\Cache",
        "$env:APPDATA\Code\CachedData",
        "$env:LOCALAPPDATA\JetBrains"
    ) | Where-Object { $_ }
    $buckets += @{
        id = 'devcache'; label = 'Developer caches'
        safety = 'auto'; undoable = $true; needsAdmin = $false; kind = 'files'
        Roots = $devCacheRoots
        Filter = { param($f) $true }
    }

    # ---- files: browser caches (must be closed first) -----------------
    $buckets += @{
        id = 'browsercache'; label = 'Browser cache (Chrome/Edge)'
        safety = 'auto'; undoable = $true; needsAdmin = $false; kind = 'files'
        RequiresClosed = @('chrome', 'msedge')
        Roots = @(
            "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
            "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache"
        )
        Filter = { param($f) $true }
    }

    # ---- command: Recycle Bin -----------------------------------------
    $buckets += @{
        id = 'recyclebin'; label = 'Recycle Bin'
        safety = 'auto'; undoable = $false; needsAdmin = $false; kind = 'command'
        Measure = {
            try {
                $shell = New-Object -ComObject Shell.Application
                $items = $shell.NameSpace(0xA).Items()
                ($items | Measure-Object -Property Size -Sum).Sum
            } catch { 0 }
        }
        Clean = { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
    }

    # (No separate package-manager command bucket: the 'devcache' files bucket
    #  already covers npm/pip/yarn/pnpm/etc. and quarantine-moves them, which
    #  reclaims the same space AND is undoable. A `npm cache clean` command
    #  bucket would double-count the same bytes in the report.)

    # ---- report-only: Windows Update component store (admin) ----------
    $buckets += @{
        id = 'winsxs'; label = 'Windows Update component store (WinSxS)'
        safety = 'review'; undoable = $false; needsAdmin = $true; kind = 'report'
        Measure = { Get-FolderBytes "$env:WINDIR\WinSxS\Backup" }
        Advice = 'Run in an ELEVATED shell: DISM /Online /Cleanup-Image /StartComponentCleanup'
    }

    # ---- report-only: Delivery Optimization cache ---------------------
    $buckets += @{
        id = 'deliveryopt'; label = 'Delivery Optimization cache'
        safety = 'auto'; undoable = $false; needsAdmin = $true; kind = 'report'
        Measure = { Get-FolderBytes "$env:WINDIR\SoftwareDistribution\DeliveryOptimization" }
        Advice = 'Elevated: Delete-DeliveryOptimizationCache -Force  (or clear via Storage Settings)'
    }

    # ---- report-only: crash dumps + Windows Error Reporting -----------
    $buckets += @{
        id = 'crashdumps'; label = 'Crash dumps + Error Reporting'
        safety = 'auto'; undoable = $false; needsAdmin = $false; kind = 'report'
        Measure = {
            (Get-FolderBytes "$env:LOCALAPPDATA\CrashDumps") +
            (Get-FolderBytes "$env:PROGRAMDATA\Microsoft\Windows\WER")
        }
        Advice = 'Clear via Storage Settings > Temporary files, or delete %LOCALAPPDATA%\CrashDumps contents.'
    }

    # ---- report-only: Windows.old -------------------------------------
    $buckets += @{
        id = 'windowsold'; label = 'Windows.old (previous install)'
        safety = 'review'; undoable = $false; needsAdmin = $true; kind = 'report'
        Measure = { Get-FolderBytes 'C:\Windows.old' }
        Advice = 'Only via Storage Settings > Temporary files > "Previous Windows installation(s)". Do NOT rm it.'
    }

    # ---- report-only: WSL2 / Docker vhdx bloat ------------------------
    $buckets += @{
        id = 'vhdx'; label = 'WSL2 / Docker virtual disk bloat'
        safety = 'review'; undoable = $false; needsAdmin = $false; kind = 'report'
        Measure = {
            $sum = 0
            Get-ChildItem "$env:LOCALAPPDATA\Packages", "$env:LOCALAPPDATA\Docker" -Recurse -File -Filter *.vhdx -ErrorAction SilentlyContinue |
                ForEach-Object { $sum += $_.Length }
            $sum
        }
        Advice = 'Compact (frees only unused space, safe): wsl --shutdown, then Optimize-VHD, or `docker system prune`. Never delete the .vhdx.'
    }

    return $buckets
}
