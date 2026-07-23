# Cleanup bucket catalog

Every bucket the skill knows about. `scripts/buckets.ps1` is the machine-readable
source of truth; this file is the human explanation. IDs here match the `-Bucket`
and `-Buckets` arguments of `scan.ps1` / `clean.ps1`.

## Contents

- [Safety classes](#safety-classes)
- [File buckets (quarantine-backed)](#file-buckets-quarantine-backed)
  - temp, downloads, node_modules, devcache, browsercache
- [Command buckets (permanent)](#command-buckets-permanent)
  - recyclebin
- [Report-only buckets (never auto-deleted)](#report-only-buckets-never-auto-deleted)
  - winsxs, deliveryopt, crashdumps, windowsold, vhdx

## Safety classes

| Field | Meaning |
| --- | --- |
| `auto` | Clearable as a batch once the user confirms the batch. |
| `review` | Every item shown; the user picks individual files. |
| `undoable = quarantine` | `clean.ps1` moves files to `%LOCALAPPDATA%\cleanup-quarantine\<stamp>\`; `restore.ps1` brings them back for 7 days. |
| `undoable = permanent` | No undo. The confirmation prompt must say so. |
| `needsAdmin` | Requires an elevated shell — the skill hands the exact command to the user, never force-runs it. |

## File buckets (quarantine-backed)

Enumerated by `scan.ps1`, cleared by moving to quarantine. `clean.ps1` re-checks
every path against the roots below and refuses anything outside them or under a
protected folder (Documents, Desktop, Pictures/Video/Music, OneDrive, Dropbox).

### temp — Temp / system junk
- **Roots**: `%TEMP%`, `%WINDIR%\Temp`
- **Safety**: auto · quarantine
- All files. The single safest bucket.

### downloads — Downloads (large/old)
- **Root**: `%USERPROFILE%\Downloads` (depth 1)
- **Safety**: review · quarantine
- Only files ≥ 100 MB **or** older than 90 days are listed. Downloads is personal
  space, never auto-cleared. A file whose name suggests a backup or archive
  (`*backup*`, `*.zip` of a project) is the user's to confirm by name — surface it,
  don't recommend deleting it.

### node_modules — Stale node_modules
- **Root**: `%USERPROFILE%` (recursion depth 6, junctions skipped)
- **Safety**: review · quarantine
- Only `node_modules` directories whose **parent project** has not been modified in
  60 days. `deep` mode only. Deleting a live one breaks the project until
  `npm install` — hence review, not auto.

### devcache — Developer caches
- **Roots**: npm-cache, Yarn, pnpm, pip, cargo registry cache, go module download
  cache, gradle caches, maven `.m2`, nuget packages, uv, poetry, VS Code cache,
  JetBrains cache.
- **Safety**: auto · quarantine
- All rebuild on demand. Quarantine-moving them reclaims the space and is
  reversible, so there is no separate `npm cache clean` command bucket (it would
  double-count the same bytes).

### browsercache — Browser cache (Chrome/Edge)
- **Roots**: Chrome + Edge `Default\Cache` and `Code Cache`
- **Safety**: auto · quarantine · **RequiresClosed: chrome, msedge**
- `clean.ps1` refuses this bucket while `chrome` or `msedge` is running — clearing a
  live profile's cache can corrupt it. Close the browser first; the skill never
  force-kills it.

## Command buckets (permanent)

Run a fixed command. No quarantine, no undo — the confirmation must state that.

### recyclebin — Recycle Bin
- **Safety**: auto · permanent
- `Clear-RecycleBin -Force`. Emptying the bin is itself the "are you sure" — treat
  it as permanent and say so.

## Report-only buckets (never auto-deleted)

`scan.ps1` measures these and prints the exact command; `clean.ps1` refuses to act
on them. These are the biggest wins on many machines but also the most dangerous to
automate, so they stay in the user's hands.

### winsxs — Windows Update component store
- **needsAdmin** · permanent
- Measures `WinSxS\Backup`. Command: `DISM /Online /Cleanup-Image /StartComponentCleanup`
  in an elevated shell. Never `rm` WinSxS directly — it breaks servicing.

### deliveryopt — Delivery Optimization cache
- **needsAdmin** · permanent
- Windows Update peer-cache. Command: `Delete-DeliveryOptimizationCache -Force`
  (elevated), or Storage Settings.

### crashdumps — Crash dumps + Error Reporting
- permanent
- `%LOCALAPPDATA%\CrashDumps` and `%PROGRAMDATA%\Microsoft\Windows\WER`. Clear via
  Storage Settings > Temporary files, or delete the CrashDumps contents.

### windowsold — Windows.old
- **needsAdmin** · permanent · review
- The previous Windows install, often 15–30 GB. **Only** remove via Storage
  Settings > Temporary files > "Previous Windows installation(s)". Never `rm` it —
  a manual delete can leave the system unbootable-recoverable state and blocks
  rollback.

### vhdx — WSL2 / Docker virtual disk bloat
- review · report
- `.vhdx` files grow but never shrink on their own. **Compaction** reclaims unused
  space without losing data: `wsl --shutdown` then `Optimize-VHD`, or
  `docker system prune`. Never delete the `.vhdx` — it is the disk.
