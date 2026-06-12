#!/bin/bash
# Records session start time for time tracking.
# Fires on SessionStart hook.

[[ -n "$TIMELOG_DISABLE" ]] && exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[[ -z "$SESSION_ID" ]] && exit 0

mkdir -p "$HOME/.claude/timelog/sessions"

echo "{\"ts\":$(date +%s),\"event\":\"start\",\"cwd\":\"$CWD\"}" \
  >> "$HOME/.claude/timelog/sessions/$SESSION_ID.jsonl"

exit 0
