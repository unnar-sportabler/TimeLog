#!/bin/bash
# Tracks file edits per repo/ticket for time logging.
# Fires on PostToolUse for Write|Edit.

[[ -n "$TIMELOG_DISABLE" ]] && exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[[ -z "$FILE_PATH" || -z "$SESSION_ID" ]] && exit 0

# Find the git repo root for this file
REPO_ROOT=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null)
[[ -z "$REPO_ROOT" ]] && exit 0

REPO_NAME=$(basename "$REPO_ROOT")

# Extract Jira ticket key from branch name (e.g. feature/AB-123-desc -> AB-123)
# Restricted to real project prefixes to avoid false matches.
BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
TICKET=$(echo "$BRANCH" | grep -oiE '\bAB-[0-9]+\b' | head -1 | tr '[:lower:]' '[:upper:]')
TICKET="${TICKET:-unknown}"

mkdir -p "$HOME/.claude/timelog/sessions"

echo "{\"ts\":$(date +%s),\"repo\":\"$REPO_NAME\",\"ticket\":\"$TICKET\",\"file\":\"$(basename "$FILE_PATH")\"}" \
  >> "$HOME/.claude/timelog/sessions/$SESSION_ID.jsonl"

exit 0
