<#
    restore.ps1 — undo a clean.ps1 run. Moves every quarantined file back to
    its original location. Reports conflicts instead of overwriting.

    Usage:
      restore.ps1 -Manifest %LOCALAPPDATA%\cleanup-quarantine\<stamp>\manifest.json
      restore.ps1 -Manifest ... -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$Manifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Manifest)) { throw "Manifest not found: $Manifest" }

# manifest.json is one compact JSON object per line (append-only from clean.ps1).
$entries = Get-Content -LiteralPath $Manifest | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }

$restored = 0; $conflicts = 0; $missing = 0
foreach ($e in $entries) {
    if (-not (Test-Path -LiteralPath $e.quarantined)) {
        Write-Warning "Missing from quarantine (already purged?): $($e.original)"
        $missing++; continue
    }
    if (Test-Path -LiteralPath $e.original) {
        Write-Warning "Conflict — a file already exists at $($e.original). Left in quarantine."
        $conflicts++; continue
    }
    if ($PSCmdlet.ShouldProcess($e.original, 'restore')) {
        New-Item -ItemType Directory -Force -Path (Split-Path $e.original -Parent) | Out-Null
        Move-Item -LiteralPath $e.quarantined -Destination $e.original -Force -ErrorAction Stop
        $restored++
    }
}

Write-Host ("Restored: {0}  Conflicts: {1}  Missing: {2}" -f $restored, $conflicts, $missing)
if ($conflicts) { Write-Host "Conflicted files remain in quarantine — resolve the originals, then re-run." }
