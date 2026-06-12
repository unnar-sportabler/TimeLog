# TimeLog

Automatic time tracking for AI coding sessions → review UI → Tempo worklogs.

Hooks record activity from Claude Code sessions (prompts, edits, tool use) with
idle detection, split it per day and Jira ticket, and a local web UI lets you
review, drag-adjust, and submit straight to Tempo.

## Install

```bash
git clone <repo-url> ~/sportabler/TimeLog
bash ~/sportabler/TimeLog/install.sh
```

Re-run `install.sh` after every `git pull` — it copies files into place and is
idempotent. Then paste tokens once: http://localhost:8377 → ⚙️ Tokens & settings.

## What gets installed where

| Target | What |
|--------|------|
| `~/.claude/timelog/app/` | runtime: hook scripts, CLI, server, UI, tests |
| `~/.claude/commands/` | skills: `/submit-times`, `/review-times`, `/timelog-ui` |
| `~/.claude/settings.json` | tracking hooks (merged, non-timelog entries untouched) |
| `~/Library/LaunchAgents/io.abler.timelog-server.plist` | UI server, auto-start + keep-alive |
| `~/Applications/Timelog.app` | dock launcher |

Data (never in git): `~/.claude/timelog/{daily,sessions,overrides}`,
`tickets.json` (Jira title cache), `config.json` (Jira base URL),
`jira-credentials` (tokens, chmod 600).

## How it works

```
session ──hooks──▶ sessions/<id>.jsonl ──session end──▶ daily/<date>.jsonl
                                                            │
                          review UI (drag/edit/submit) ─or─ /submit-times
                                                            │
                                                       Tempo worklogs
```

- **Tracking**: `track-prompt` (extracts `AB-####`, meta detection, `ignoretime`
  opt-out keyword), `track-edit` (repo + branch ticket), `track-activity`
  (every turn/tool — Bash-heavy sessions count), `session-end` (idle-aware
  duration, midnight split with ticket inheritance, idempotent upsert, macOS
  dialog for unknown-ticket sessions).
- **CLI** (`timelog-cli.py`): `list`, `day` (15-min bucketing, fill-to-target
  distribution, honors UI drag-locks), `mark-logged`, `missing-titles`, `set-titles`.
- **UI** (localhost:8377, stdlib only): drag bars (15-min snap), rename tickets
  (with Jira links + titles), inspect session prompts, mark not-work, per-day
  target + auto-fill toggle, submit day to Tempo.
- **Skills**: `/submit-times` (submit via Claude + Tempo MCP), `/review-times`
  (terminal cleanup), `/timelog-ui` (launch UI).

## Other agents (Codex, …)

The tracker is agent-agnostic at the data layer: anything that appends
`{"ts": …, "event": …}` lines to `~/.claude/timelog/sessions/<id>.jsonl` and
invokes `session-end.sh` on exit participates. Hook adapters for other tools
can live next to `hooks/` later; CLI/UI/submission need no changes.

## Tests

```bash
python3 ~/.claude/timelog/app/test-timelog.sh
```
