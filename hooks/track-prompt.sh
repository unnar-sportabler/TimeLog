#!/bin/bash
# Records user prompt activity for time tracking.
# Extracts ticket from prompt text, detects meta sessions and "ignoretime" opt-out.
# Fires on UserPromptSubmit hook.

[[ -n "$TIMELOG_DISABLE" ]] && exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')

[[ -z "$SESSION_ID" ]] && exit 0

LOG="$HOME/.claude/timelog/sessions/$SESSION_ID.jsonl"
mkdir -p "$HOME/.claude/timelog/sessions"

# "ignoretime" anywhere in any prompt — exclude this whole session from time submission
if echo "$PROMPT" | grep -iqE '\bignoretime\b'; then
  echo "{\"ts\":$(date +%s),\"event\":\"ignore\"}" >> "$LOG"
fi

# Only match real Jira project keys — generic [A-Z]+-[0-9]+ produced false tickets (M-1, H-4, UTF-8)
TICKET=$(echo "$PROMPT" | grep -oiE '\bAB-[0-9]+\b' | head -1 | tr '[:lower:]' '[:upper:]')
TICKET="${TICKET:-}"

# Check if this is a meta/time-management prompt
META_FLAG=false
if echo "$PROMPT" | grep -iqE 'submit-times|review-times|submit times|review times|time log|timelog|log time|tempo|worklog|ignoretime'; then
  META_FLAG=true
fi

jq -cn --argjson ts "$(date +%s)" --arg ticket "$TICKET" --argjson meta "$META_FLAG" \
  '{ts: $ts, event: "prompt", ticket: $ticket, meta: $meta}' \
  >> "$LOG"

exit 0
