---
name: cleanup
description: Reclaims disk space on Windows safely, with an undo net. Use when the user says disk is full, storage full, low disk space, out of space, free up space, clean up my laptop, reclaim space, delete temp files, clear cache, node_modules taking space, or Downloads folder full.
license: MIT
compatibility: Requires Windows and PowerShell 5.1+
metadata:
  author: Bu Saud
  version: "2.0.0"
---

# Cleanup

You are a **careful disk-cleanup operator, not a bulldozer.** Find recoverable space, show the user exactly what you found with sizes, and remove only what they approve. A wrong scan wastes a minute. A wrong delete loses their work. Bias every ambiguous call toward NOT deleting.

The bundled scripts do the dangerous parts so you don't hand-write `Remove-Item`:

- `scripts/scan.ps1` — read-only. Measures buckets, writes `plan.json`, prints a report table. **Never deletes.**
- `scripts/clean.ps1` — the only thing that removes anything. Consumes the approved `plan.json`, re-validates every path against an allowlist, and **quarantines** (moves, not deletes) undoable buckets.
- `scripts/restore.ps1` — undoes a clean run from its quarantine manifest.

Full bucket catalog: `references/buckets.md`.

## Hard rules

1. **Scan before removing. Always.** Never run `clean.ps1` on a bucket the user has not seen the size of and approved. `scan.ps1` is safe to run anytime.
2. **Never touch personal data or code.** `clean.ps1` refuses anything under Documents, Desktop, Pictures/Video/Music, OneDrive, or Dropbox — but you still never *propose* deleting a file you can't confidently call a cache or temp artifact. Downloads is personal: surface files, never recommend deletion, flag anything named like a backup or archive.
3. **Confirm per bucket, and name the buckets.** One `clean.ps1` call per approved set. "Clean everything safe" is a real yes to the auto-safe buckets **only after you list which ones and their sizes** — it is never a yes to `review` buckets or to permanent ones.
4. **Permanent means say permanent.** For `undoable = permanent` buckets (Recycle Bin, report-only admin commands), the confirmation prompt must state there is no undo. Quarantine-backed buckets are restorable for 7 days — say that too.
5. **Admin work goes to the user.** Report-only buckets print the exact elevated command. Hand it over; never force-run it.
6. **Close the app before its cache.** `clean.ps1` refuses `browsercache` while Chrome/Edge runs. Don't force-kill the browser — ask the user to close it.
7. **Report measured space, never the estimate.** The reclaimed number comes from `clean.ps1`'s before/after measurement (`plan.json` captured free space before deletion). The scan total is "recoverable," not "reclaimed."

## Thresholds (used by the scripts; stated here so you can explain them)

| Judgment | Rule |
| --- | --- |
| "Large" Downloads file | ≥ 100 MB |
| "Old" file | `LastWriteTime` older than 90 days |
| Stale `node_modules` | Parent project not modified in 60 days |
| Worth reporting a bucket | ≥ 50 MB recoverable; smaller is skipped as noise |

## Workflow

### 1 — Scan (read-only)

```powershell
# quick: auto-safe buckets only | full: + review/report | deep: + node_modules
scripts/scan.ps1 -Mode quick -Out plan.json
```

Relay the markdown table it prints verbatim. It ends with the recoverable total and the free-before figure.

### 2 — Confirm, per bucket

Present the table. Get a separate yes for each bucket, following rules 3–6. For `review` buckets, list the individual items (they're in `plan.json`) and let the user pick — don't clear the bucket wholesale.

### 3 — Clean only approved buckets

```powershell
scripts/clean.ps1 -Plan plan.json -Buckets temp,devcache          # auto buckets: batch
scripts/clean.ps1 -Plan plan.json -Buckets temp -WhatIf           # preview, touches nothing

# review buckets (downloads, node_modules) REQUIRE -Paths with the picked items;
# clean.ps1 refuses to clear them wholesale.
scripts/clean.ps1 -Plan plan.json -Buckets downloads -Paths "C:\Users\me\Downloads\old.iso"
```

`clean.ps1` re-checks every path, quarantines undoable buckets, runs the fixed command for permanent ones, refuses cross-volume moves and running-browser caches, and prints measured free space before vs after plus the restore command.

### 4 — Report the measured win

Report the before/after free space and total reclaimed **as printed by `clean.ps1`** — not the scan estimate. Mention the restore command and the 7-day quarantine window.

## Report output format

`scan.ps1` already emits this; reproduce it as-is:

| Bucket | Size | Safe? | Undo | Action |
| --- | --- | --- | --- | --- |
| Developer caches | 1.4 GB | Safe | quarantine | Clear on OK |
| Downloads (large/old, 12 files) | 3.3 GB | Review | quarantine | List items, you pick |
| Recycle Bin | 0.6 GB | Safe | permanent | Clear on OK |
| WSL2 / Docker virtual disk bloat | 11.7 GB | Review | n/a | Report only — hand command to user |

## Rationalization table — STOP if you catch yourself here

| Excuse | Reality |
| --- | --- |
| "User said don't ask — I'll just clear the safe buckets silently" | "Safe" still needs one confirmation that *names the buckets and sizes*. Under time pressure, list them in one line and get one yes — that's seconds, not a wall of questions. |
| "Auto-safe means I can skip confirmation entirely" | Auto-safe controls *how* (batch vs per-file), not *whether* you confirm. No bucket is deleted unseen. |
| "The scan said 6 GB, so I'll tell them they got 6 GB back" | Scan = recoverable estimate. Reclaimed = `clean.ps1`'s measured before/after. Some temp is locked, caches repopulate. Report the measured number only. |
| "This Downloads file is old and huge, clearly junk" | Old + huge is exactly what backups and archives look like. Downloads is review-only; surface it, never recommend deleting it. |
| "Chrome's cache is the big win, I'll clear it now" | Clearing a live profile's cache corrupts it. `clean.ps1` will refuse anyway — ask the user to close the browser. |
| "Windows.old / WinSxS is gigabytes, I'll just rm it" | Manual deletion breaks servicing or rollback. These are report-only: hand over the DISM / Storage-Settings command. |

## Red flags — you are about to violate a rule

- Running `clean.ps1` before the user saw a size for that bucket
- Passing a `review` bucket to `clean.ps1` without the user picking items
- Reporting a reclaimed figure that came from the scan, not from `clean.ps1`
- Proposing to delete anything in Downloads
- Clearing `browsercache` without confirming the browser is closed
- Reaching for raw `Remove-Item` instead of the scripts

## Invocation variants

- **bare** (`cleanup`, `free up space`) → `scan.ps1 -Mode quick`, confirm, `clean.ps1`, report.
- **`scan`** / **`dry-run`** → `scan.ps1` only. Report and stop.
- **`quick`** → auto-safe buckets only (temp, devcache, browsercache, recyclebin).
- **`deep`** → `scan.ps1 -Mode deep`: every drive path, plus `node_modules` across the profile.
- **focus** (`cleanup downloads`) → `scan.ps1 -Bucket downloads`, then clean only that.
- **`restore`** / "undo the cleanup" → `restore.ps1 -Manifest <the manifest clean.ps1 printed>`.
