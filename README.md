# Abdullah Skills

A collection of agent skills for Claude Code and other agents that support the
[`skills`](https://github.com/vercel-labs/skills) format. Each skill is a folder
under `skills/` with a `SKILL.md` file. Install any of them with one command.

## Skills

| Skill | What it does | Platform |
| --- | --- | --- |
| **cleanup** | Frees up disk space, safely. Scans temp/system junk, dev caches, stray `node_modules`, Downloads, browser caches, and the big Windows wins (Windows Update store, WSL/Docker vhdx bloat), reports sizes, and removes only after you confirm — one bucket at a time. Deletions are quarantined, not destroyed, so a wrong call is undoable for 7 days. | Windows (PowerShell) |

## Install

Install everything in this repo:

```bash
npx skills add YOURUSERNAME/abdullah-skills
```

Install a single skill:

```bash
npx skills add YOURUSERNAME/abdullah-skills --skill cleanup
```

See what's in the repo before installing:

```bash
npx skills add YOURUSERNAME/abdullah-skills --list
```

Skills install into `.claude/skills/` (or your agent's skills directory). Once
installed, just describe the task in plain language and the matching skill runs.
For `cleanup`, say `cleanup`, `free up space`, or `scan` for a report-only pass.

> Replace `YOURUSERNAME` with your GitHub username once this repo is pushed.

## Using cleanup

- `cleanup` or `free up space` — full run: scan, confirm per bucket, clean, report.
- `scan` / `dry-run` — report only, removes nothing.
- `quick` — only the auto-safe buckets (temp, dev caches, browser cache, Recycle Bin).
- `deep` — all buckets, plus stale `node_modules` across your profile.
- `cleanup downloads` — focus on one bucket.
- `restore` / "undo the cleanup" — put back the last run's quarantined files.

It never removes anything without showing you sizes first and getting a separate
yes for each bucket. Personal files, source code, and secrets are always
off-limits — the cleaner re-checks every path against an allowlist and refuses
anything under Documents, Desktop, OneDrive, or Dropbox. Undoable buckets are
**moved to quarantine**, not deleted, and restorable for 7 days; permanent
buckets (Recycle Bin) and admin-only wins (Windows Update store, `Windows.old`)
are always called out as such before anything runs.

Under the hood the skill ships three PowerShell scripts — `scan.ps1` (read-only),
`clean.ps1` (the only one that removes anything, via quarantine), and
`restore.ps1` (undo) — plus `references/buckets.md` documenting every bucket.

## Adding a new skill

1. Create `skills/<your-skill-name>/SKILL.md`.
2. Give it frontmatter with a `name` and a trigger-rich `description` (pack in the
   exact phrases a user would type — that's what makes the skill fire).
3. Write the instructions: a role line, hard rules, a phased workflow, exact
   values instead of vibes, an owned output format, and a checklist.
4. Add a row to the Skills table above.
5. Commit and push. It's instantly installable with `npx skills add`.

## License

MIT
