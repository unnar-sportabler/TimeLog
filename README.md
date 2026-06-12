# TimeLog

Automatic time tracking for AI coding sessions → review UI → Tempo worklogs.

Hooks record activity from Claude Code sessions (prompts, edits, tool use) with
idle detection, split it per day and Jira ticket, and a local web UI lets you
review, drag-adjust, and submit straight to Tempo.

## Install

```bash
git clone https://github.com/unnar-sportabler/TimeLog.git ~/sportabler/TimeLog
bash ~/sportabler/TimeLog/install.sh
```

Re-run `install.sh` after every `git pull` — it copies files into place and is
idempotent. Then paste tokens once: http://localhost:8377 → ⚙️ Tokens & settings.

## Prompting so your time lands on the right ticket

The tracker reads ticket signals from your prompts and git branches. A few
habits make the difference between clean days and ⚠️ unknown cleanup:

- **Mention the ticket in your first prompt.** `AB-12345 fix the login flow` —
  the key is extracted from anywhere in any prompt (`AB-####` pattern only;
  other shapes are ignored). One mention is enough for the whole session.
- **Work on ticket branches.** Every file edit picks its ticket from the branch
  name (`feature/AB-12345-login-fix`), repo from the git root. Edits are the
  strongest signal — branch discipline ≈ zero manual cleanup.
- **Sessions spanning midnight are fine.** The after-midnight part inherits the
  session's dominant ticket automatically.
- **Multiple tickets in one session work** — time is split proportionally to
  each ticket's share of activity signals (prompt mentions + edits).

### Excluding non-work sessions

- Type **`ignoretime`** anywhere in any prompt — the whole session is marked
  meta and never reaches Tempo. Use it the moment a session turns out to be a
  quick question, config fiddling, or experimentation.
- Sessions whose first prompt mentions time tracking itself (`submit-times`,
  `tempo`, `worklog`, …) are auto-flagged meta.
- Forgot? The session-end dialog (work session ≥10 min with no ticket) has a
  **Not work** button, and the UI / `/review-times` can mark any row 🚫
  not-work afterwards.

### When a session ends with no ticket

A macOS dialog asks for one (45s timeout, Skip keeps it unknown). Unknown rows
show ⚠️ in the UI — expand "▸ sessions" to see the first prompts and decide:
assign a ticket, mark not-work, or delete.

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
