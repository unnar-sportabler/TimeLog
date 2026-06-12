#!/bin/bash
# Appends a bare activity timestamp to the session log. Fires on Stop (Claude
# finished a turn) and PostToolUse (any tool) — so Bash/Read-heavy sessions
# with no file edits still accumulate active time.

[[ -n "$TIMELOG_DISABLE" ]] && exit 0

SESSION_ID=$(cat | jq -r '.session_id // empty')
[[ -z "$SESSION_ID" ]] && exit 0

mkdir -p "$HOME/.claude/timelog/sessions"
echo "{\"ts\":$(date +%s),\"event\":\"activity\"}" \
  >> "$HOME/.claude/timelog/sessions/$SESSION_ID.jsonl"

exit 0
