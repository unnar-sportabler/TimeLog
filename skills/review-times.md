---
description: Review and clean unsubmitted timelog entries — assign tickets, merge sessions, delete junk. No Tempo submission.
---

## Purpose

Review and clean up unsubmitted time entries before submitting. Use this to assign tickets, merge sessions, fix repos, or delete junk entries. Changes are saved back to the file. No Tempo submissions happen here.

---

## Step 1 — Pick a day

Run:

```bash
ls ~/.claude/timelog/daily/*.jsonl 2>/dev/null
```

For each file, collect unsubmitted entries (`"logged": false` or absent). Compute total minutes.

Show the day picker:

```
Days with unsubmitted entries:
1. 2026-03-09  (12 sessions · 50m)
2. 2026-03-08  (3 sessions  · 2h 10m)

Pick a day to review:
```

If nothing to review, say "No unsubmitted entries to review." and stop.

Wait for the user's input.

---

## Step 2 — Load descriptions and show session table

Read the file for the chosen day and collect all unsubmitted entries. Each entry is one session row.

**For each entry, resolve its description:**

- If `description` field is non-empty → use it as-is (generated from file edits at session end).
- If `description` is empty or missing → find the session transcript:
  ```bash
  ls ~/.claude/projects/*/<session_id>.jsonl 2>/dev/null | head -1
  ```
  Read the first user message from that file (scan lines until you find `"role":"user"` with a text content block). Use the first 120 characters of that message as the description. If no transcript found, use `"(no description)"`.

Display one row per session. **Separate work entries from meta entries** — show work entries first (numbered, actionable), then meta entries in a dimmed section (not numbered, not submittable):

```
### 2026-03-09 — Review mode
| # | Ticket     | Repos    | Time | Edits | Description                          |
|---|------------|----------|------|-------|--------------------------------------|
| 1 | ⚠️ unknown  | (none)   | 21m  | 0     | implement the following plan: Mu...  |
| 2 | PROJ-123   | nest-api | 45m  | 12    | Edited ksi-live.service.ts in nes... |

Meta sessions (skipped in /submit-times):
  · 9m  — check what mcp servers are currently set up
  · 3m  — submit-times
```

Only work entries (`category: "work"` or absent) get row numbers and are eligible for actions.

Show `(none)` if repos list is empty. Format time as `Xh Ym` (omit `0h`). Mark `ticket: "unknown"` with ⚠️.

Then show the actions menu:

```
Actions:
  t <#> — set ticket           (e.g. t 1)
  r <#> — set repos            (e.g. r 1)
  m <#> <#> — merge rows       (e.g. m 1 2)
  d <#> [<#> ...] — delete one or more rows  (e.g. d 1  or  d 1 3 5)
  DELETE_DAY — delete the entire day's file
  s — save and exit
  q — quit without saving
```

Wait for the user's action input.

---

## Step 3 — Handle actions (loop until save or quit)

After each action, re-display the updated table and actions menu.

### `t <#>` — Set ticket
Ask: "Ticket for entry #N?" → update that entry's ticket in memory.

### `r <#>` — Set repos
Ask: "Repos for entry #N? (comma-separated, e.g. nest-api, abler-ai)" → update repos list in memory.

### `m <#> <#>` — Merge rows
Combine two rows into one: sum minutes and edit_count, union repos, concatenate descriptions (separated by " / "), keep the ticket from the first row (if they differ, ask which to keep). Remove the second row.

### `d <#> [<#> ...]` — Delete one or more rows
Accept one or more row numbers (e.g. `d 1`, `d 1 3`, `d 2 4 5`).
If a single row: confirm "Delete entry #N (`<ticket>`, `<time>`, `<description>`)? (y/n)"
If multiple rows: list them all in the confirmation — "Delete entries #1, #3, #5? (y/n)"
If yes, mark all specified entries for deletion.

### `s` — Save and exit
Rewrite the `.jsonl` file to reflect all in-memory changes:
- For each entry: apply ticket/repos/description changes; remove entries marked for deletion
- Keep all `"logged": true` entries untouched
- Write back using the Bash tool with a Python one-liner or heredoc

Confirm: "Saved. Run /submit-times when ready to submit."

### `DELETE_DAY`
Confirm: "Delete all entries for YYYY-MM-DD and remove the file? (y/n)"
If yes, run:
```bash
rm ~/.claude/timelog/daily/YYYY-MM-DD.jsonl
```
Then say "Deleted. No entries remain for YYYY-MM-DD." and stop.

### `q` — Quit without saving
Discard all in-memory changes. Say "No changes saved."
