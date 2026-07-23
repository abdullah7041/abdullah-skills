# Abdullah Skills

A collection of agent skills for Claude Code and other agents that support the
[`skills`](https://github.com/vercel-labs/skills) format. Each skill is a folder
under `skills/` with a `SKILL.md` file. Install any of them with one command.

## Skills

| Skill | What it does | Platform |
| --- | --- | --- |
| **cleanup** | Frees up disk space, safely. Scans temp/system junk, dev caches, stray `node_modules`, Downloads, and browser caches, reports sizes, and deletes only after you confirm — one bucket at a time. | Windows (PowerShell) |

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

- `cleanup` or `free up space` — full run: scan, confirm per bucket, delete, verify.
- `scan` / `dry-run` — report only, deletes nothing.
- `quick` — only the always-safe buckets (temp, Recycle Bin, dev caches).
- `deep` — all drives, plus duplicates and node_modules everywhere.
- `cleanup downloads` — focus on one bucket.

It never deletes without showing you sizes first and getting a separate yes for
each category. Personal files, source code, and secrets are always off-limits.

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
