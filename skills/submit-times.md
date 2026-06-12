---
description: Submit unsubmitted timelog entries to Tempo worklogs — 15-min buckets, fills the day to a target (default 8h)
---

All grouping, bucketing, and time-distribution math is done by the CLI — never compute it yourself. Run it, display its output, relay user choices back as flags.

```
CLI=python3 ~/.claude/timelog/app/timelog-cli.py
```

## Step 1 — Discover unsubmitted days

Run **only** this (no Tempo call yet — keep the list instant):

```bash
python3 ~/.claude/timelog/app/timelog-cli.py list
```

Show its output verbatim (it already includes the picker prompt). If it says no entries found, stop. Wait for the user's input.

## Step 2 — Show detail for chosen day(s)

If the user picks a number, work on that day. If "all", process days oldest-first, one at a time, repeating this step.

**If the selected day is today**, warn: "⚠️ Today's sessions that are still open haven't been written to the log yet (they flush on session end). Totals may be incomplete." — then continue.

1. **First day this run only** — in one turn, in parallel:
   - Call `retrieveWorklogs` once with `from` = oldest listed date and `to` = newest listed date. Build a per-day cache: `already[date] = round(sum of that date's timeSpentSeconds / 60)`; days absent from the result = 0. If the call **errors**, warn ("Couldn't check existing Tempo worklogs — continuing may double-fill the day") and ask whether to continue with 0 or cancel.
   - Run `python3 ~/.claude/timelog/app/timelog-cli.py missing-titles`. If it prints any ticket keys **and** an Atlassian/Jira MCP tool is available, fetch those issues' summaries (batch, e.g. JQL `key in (AB-1, AB-2)`), then pipe them in:
     ```bash
     echo '{"AB-123": "Issue summary", ...}' | python3 ~/.claude/timelog/app/timelog-cli.py set-titles
     ```
     Titles are cached permanently in `~/.claude/timelog/tickets.json` — fetched once per ticket, ever. If no Jira tool is available or the fetch fails, skip silently — the table shows bare keys.

   **Subsequent days**: cache lookups only, no network.
2. Run:
   ```bash
   python3 ~/.claude/timelog/app/timelog-cli.py day <YYYY-MM-DD> --already <minutes>
   ```
   (The table shows `KEY — title` from the title cache automatically.)
3. Display the header and table verbatim. Do **not** display the trailing ```json block — that's submission data for you.

Then offer:

```
1. Submit all
2. Edit entry (by #) — change ticket / time / description
3. Skip entry (by #)
4. Override target hours — change 8h default (e.g. if you worked 10h)
5. Cancel
```

Wait for the user's choice.

## Step 3 — Handle edits, skips, and target override

Every change is a flag on the `day` command. Keep all previously chosen flags and re-run with the new one added, then re-display table + menu. Flags always reference the **original** row numbers (they stay stable across re-runs).

- **Change ticket** → `--set-ticket N=AB-123`
- **Change time** → `--lock N=<minutes>` (locks that entry; the CLI redistributes the rest)
- **Change description** → no flag; remember it and use it at submit time
- **Skip (3)** → `--skip N`
- **Override target (4)** → ask "New target hours? (default: 8)", parse decimal hours, `--target <round(hours*60)>`
- **Cancel (5)** → stop immediately, no changes.

## Step 4 — Submit

On "Submit all", use the JSON block from the **latest** `day` run. For each group:

- If `ticket` is `"unknown"`, ask: "What Jira ticket for entry #N (`<repos>`, `<allocated time>`)?" — wait for the answer.
- Call `createWorklog`:
  - `issueKey`: the ticket
  - `timeSpentHours`: from the JSON
  - `date`: the day being processed (**not** today)
  - `description`: user-provided if edited, else `"Work on <ticket> in <repos>"` (no repos → `"Work on <ticket>"`)
- **On success**, immediately run:
  ```bash
  python3 ~/.claude/timelog/app/timelog-cli.py mark-logged <YYYY-MM-DD> --ticket <original_ticket> --repos "<comma-separated repos, or empty string>"
  ```
  (`original_ticket` from the JSON — it's the ticket as stored in the file, even if you set a different one for submission.) The CLI marks entries `logged: true` and deletes the file once nothing unlogged remains — partial failures and reruns are safe.
- **On failure**: report the error, continue with remaining groups; those entries stay unlogged and reappear next run.

Show a per-day summary: `2026-03-09: 2 worklogs submitted (6h 0m total).`

## Step 5 — Next day (loop)

- If "all" was selected and days remain: continue with the next day from Step 2 automatically.
- If a single day was picked: re-run `list` and show the updated picker plus a "done" option, so the next day can be submitted without re-invoking /submit-times. Reuse the Tempo cache from the first pick — but add to `already[date]` the minutes you submitted this run for that date. On "done" (or no days left), finish.

## Final summary

```
Done. X worklogs submitted across Y days — Zh Wm total.
```
