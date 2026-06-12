#!/usr/bin/env python3
"""
Calculates active session duration using activity timestamps with idle detection,
splits time by repo/ticket per day, and appends entries to the daily time log.
Fires on SessionEnd hook.

Activity model:
  - Every event (start, prompt, edit) provides an activity timestamp.
  - Consecutive timestamps within IDLE_THRESHOLD are considered active time.
  - Gaps exceeding the threshold are treated as breaks and excluded.
  - If a session spans midnight, separate entries are created per calendar day.

Classification (deterministic, no LLM):
  1. "ignore" event (user typed "ignoretime")        -> meta
  2. meta keyword in first prompt                     -> meta
  3. has edits or a valid AB- ticket signal           -> work
  4. otherwise                                        -> work, unknown ticket;
     a macOS dialog asks for a ticket / "Not work" when the session is >= 10 min.

Idempotency:
  SessionEnd can fire more than once per session (resume, clear, re-exit).
  Before writing, all unlogged entries for this session_id are removed from each
  day file and replaced with the freshly computed ones (upsert, not append).
"""

import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

IDLE_THRESHOLD = 30 * 60  # seconds — gaps larger than this are breaks
DIALOG_MIN_MINUTES = 10   # don't bother asking for tiny sessions
SESSION_RETENTION_DAYS = 14
TICKET_RE = re.compile(r"\bAB-\d+\b", re.IGNORECASE)

if os.environ.get("TIMELOG_DISABLE"):
    sys.exit(0)

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

session_id = data.get("session_id", "")
if not session_id:
    sys.exit(0)

sessions_dir = Path.home() / ".claude" / "timelog" / "sessions"
session_file = sessions_dir / f"{session_id}.jsonl"
if not session_file.exists():
    sys.exit(0)

entries = []
for line in session_file.read_text().splitlines():
    line = line.strip()
    if line:
        try:
            entries.append(json.loads(line))
        except Exception:
            pass

if not entries:
    sys.exit(0)

daily_dir = Path.home() / ".claude" / "timelog" / "daily"
daily_dir.mkdir(parents=True, exist_ok=True)

# Sort all events by timestamp
entries.sort(key=lambda e: e.get("ts", 0))
timestamps = [e["ts"] for e in entries if "ts" in e]


# ---------------------------------------------------------------------------
# Active-interval calculation
# ---------------------------------------------------------------------------

def compute_active_intervals(timestamps, idle_threshold):
    """Return list of (start, end) active intervals, breaking on gaps > threshold."""
    if not timestamps:
        return []
    if len(timestamps) == 1:
        return [(timestamps[0], timestamps[0] + 60)]

    intervals = []
    interval_start = timestamps[0]
    prev = timestamps[0]
    for ts in timestamps[1:]:
        if ts - prev > idle_threshold:
            # Break detected — close current interval
            intervals.append((interval_start, prev))
            interval_start = ts
        prev = ts
    intervals.append((interval_start, prev))
    return intervals


intervals = compute_active_intervals(timestamps, IDLE_THRESHOLD)


# ---------------------------------------------------------------------------
# Split intervals by calendar day
# ---------------------------------------------------------------------------

def split_by_day(intervals):
    """Split active intervals into per-day seconds. Returns {date_str: seconds}."""
    per_day = defaultdict(int)
    for start, end in intervals:
        # Ensure at least 60s per interval
        if end <= start:
            end = start + 60
        current = start
        while current < end:
            day_str = datetime.fromtimestamp(current).strftime("%Y-%m-%d")
            dt = datetime.fromtimestamp(current)
            next_midnight = datetime(dt.year, dt.month, dt.day) + timedelta(days=1)
            next_midnight_ts = int(next_midnight.timestamp())
            day_end = min(end, next_midnight_ts)
            per_day[day_str] += day_end - current
            current = next_midnight_ts
    return dict(per_day)


per_day_seconds = split_by_day(intervals)


# ---------------------------------------------------------------------------
# Ticket signals & classification
# ---------------------------------------------------------------------------

def normalize_ticket(ticket):
    """Valid AB- key -> uppercased key; anything else -> 'unknown'."""
    if ticket and TICKET_RE.fullmatch(ticket.strip()):
        return ticket.strip().upper()
    return "unknown"


# Collect ticket signals: (timestamp, ticket, repo|None, is_edit, filename)
ticket_signals = []
for e in entries:
    ts = e.get("ts", 0)
    if "repo" in e:
        # Edit event from track-edit.sh
        ticket_signals.append((ts, normalize_ticket(e.get("ticket", "")), e.get("repo"), True, e.get("file", "")))
    elif e.get("event") == "prompt" and e.get("ticket"):
        # Prompt event with extracted ticket from track-prompt.sh
        ticket = normalize_ticket(e["ticket"])
        if ticket != "unknown":
            ticket_signals.append((ts, ticket, None, False, ""))

# Repos mentioned in prompt text — fallback for sessions with no edits
prompt_repos = sorted({r for e in entries if e.get("event") == "prompt"
                       for r in (e.get("repos") or "").split(",") if r})

# Explicit opt-out: user typed "ignoretime" in any prompt
is_ignored = any(e.get("event") == "ignore" for e in entries)

# Detect meta session from first prompt event
is_meta = False
for e in entries:
    if e.get("event") == "prompt":
        is_meta = e.get("meta", False) is True
        break

category = "meta" if (is_ignored or is_meta) else "work"


def build_edit_description(edit_signals):
    """Build description from edit signals: 'Edited file1, file2 in repo1, repo2'."""
    files = list(dict.fromkeys(s[4] for s in edit_signals if s[4]))
    repos = sorted(set(s[2] for s in edit_signals if s[2]))
    if not files:
        return ""
    file_str = ", ".join(files[:3])
    if len(files) > 3:
        file_str += f" +{len(files) - 3} more"
    return f"Edited {file_str} in {', '.join(repos)}"


# ---------------------------------------------------------------------------
# Build per-day records (in memory first; dialog may adjust them)
# ---------------------------------------------------------------------------

day_records = defaultdict(list)  # day_str -> [record, ...]

for day_str, total_seconds in sorted(per_day_seconds.items()):
    day_minutes = max(1, total_seconds // 60)

    # Collect ticket signals that fall within this day
    day_start_ts = int(datetime.strptime(day_str, "%Y-%m-%d").timestamp())
    day_end_ts = day_start_ts + 86400
    day_signals = [s for s in ticket_signals if day_start_ts <= s[0] < day_end_ts]

    if not day_signals:
        # No ticket signals on this day. If the session has signals on OTHER
        # days (midnight-spanning session), inherit the dominant ticket —
        # continuing work after midnight rarely re-mentions the ticket.
        ticket = "unknown"
        repos = []
        if ticket_signals:
            by_ticket = defaultdict(int)
            for s in ticket_signals:
                if s[1] != "unknown":
                    by_ticket[s[1]] += 1
            if by_ticket:
                ticket = max(by_ticket, key=by_ticket.get)
                repos = sorted(set(s[2] for s in ticket_signals if s[1] == ticket and s[2]))
        if not repos:
            repos = prompt_repos
        day_records[day_str].append({
            "session_id": session_id,
            "date": day_str,
            "ticket": ticket,
            "repos": repos,
            "minutes": day_minutes,
            "edit_count": 0,
            "description": "Continued session work" if ticket != "unknown" else "",
            "category": category,
            "logged": False,
        })
    else:
        # Group signals by ticket, split day's minutes proportionally
        ticket_groups = defaultdict(list)
        for sig in day_signals:
            ticket_groups[sig[1]].append(sig)

        total_signal_count = len(day_signals)
        for ticket, signals in ticket_groups.items():
            count = len(signals)
            minutes = max(1, round(day_minutes * count / total_signal_count))
            edit_signals = [s for s in signals if s[3]]
            repos = sorted(set(s[2] for s in signals if s[2])) or prompt_repos
            description = build_edit_description(edit_signals) if edit_signals else ""
            day_records[day_str].append({
                "session_id": session_id,
                "date": day_str,
                "ticket": ticket,
                "repos": repos,
                "minutes": minutes,
                "edit_count": len(edit_signals),
                "description": description,
                "category": category,
                "logged": False,
            })


# ---------------------------------------------------------------------------
# Dialog: ask for ticket / "Not work" when the session is ambiguous
# ---------------------------------------------------------------------------

def ask_dialog(minutes, repos):
    """Show a macOS dialog. Returns ('ticket', 'AB-123') | ('notwork', None) | ('skip', None)."""
    msg = f"Claude session ended: {minutes}m"
    if repos:
        msg += f" in {', '.join(repos)}"
    msg += "\nJira ticket? Or mark as not work."
    script = (
        "display dialog " + json.dumps(msg)
        + ' default answer "AB-" buttons {"Not work","Skip","OK"}'
        + ' default button "OK" giving up after 45 with title "Time log"'
    )
    try:
        out = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=60,
        )
        s = out.stdout
        if "gave up:true" in s:
            return ("skip", None)
        if "button returned:Not work" in s:
            return ("notwork", None)
        if "button returned:OK" in s:
            m = re.search(r"text returned:\s*(AB-\d+)", s, re.IGNORECASE)
            if m:
                return ("ticket", m.group(1).upper())
        return ("skip", None)
    except Exception:
        return ("skip", None)


all_records = [r for recs in day_records.values() for r in recs]
unknown_work = [r for r in all_records if r["category"] == "work" and r["ticket"] == "unknown"]
unknown_minutes = sum(r["minutes"] for r in unknown_work)

if (
    unknown_work
    and unknown_minutes >= DIALOG_MIN_MINUTES
    and not os.environ.get("TIMELOG_NO_DIALOG")
):
    repos = sorted({repo for r in unknown_work for repo in r["repos"]})
    action, ticket = ask_dialog(unknown_minutes, repos)
    if action == "ticket":
        for r in unknown_work:
            r["ticket"] = ticket
    elif action == "notwork":
        for r in all_records:
            r["category"] = "meta"
    # 'skip' -> leave unknown; /submit-times will ask


# ---------------------------------------------------------------------------
# Upsert per-day entries (idempotent on SessionEnd re-fires)
# ---------------------------------------------------------------------------

def upsert_day(daily_log, session_id, new_records):
    """Replace this session's unlogged entries in the day file with new_records."""
    kept = []
    if daily_log.exists():
        for line in daily_log.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                kept.append(line)
                continue
            if rec.get("session_id") == session_id and not rec.get("logged"):
                continue  # superseded by this run
            kept.append(line)
    lines = kept + [json.dumps(r) for r in new_records]
    daily_log.write_text("\n".join(lines) + "\n" if lines else "")


for day_str, records in sorted(day_records.items()):
    upsert_day(daily_dir / f"{day_str}.jsonl", session_id, records)


# ---------------------------------------------------------------------------
# Cleanup: drop session event files older than the retention window
# ---------------------------------------------------------------------------

cutoff = time.time() - SESSION_RETENTION_DAYS * 86400
for f in sessions_dir.glob("*.jsonl"):
    try:
        if f.stat().st_mtime < cutoff:
            f.unlink()
    except OSError:
        pass

sys.exit(0)
