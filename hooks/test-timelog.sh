#!/usr/bin/env python3
"""
Tests for the timelog hook system.
Creates fake session data, runs session-end.sh logic, and verifies output.
Run: python3 ~/.claude/timelog/app/test-timelog.sh
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path

HOOKS_DIR = Path(__file__).parent
SESSION_END = HOOKS_DIR / "session-end.sh"
TRACK_PROMPT = HOOKS_DIR / "track-prompt.sh"

# Use a temp directory for test data so we don't pollute real timelog
TIMELOG_BASE = Path(tempfile.mkdtemp(prefix="timelog-test-"))
SESSIONS_DIR = TIMELOG_BASE / "sessions"
DAILY_DIR = TIMELOG_BASE / "daily"
SESSIONS_DIR.mkdir(parents=True)
DAILY_DIR.mkdir(parents=True)

passed = 0
failed = 0


def run_session_end(session_id):
    """Run session-end.sh with patched paths."""
    # We can't easily patch Path.home() in the subprocess, so we'll import
    # and call the logic directly instead.
    pass


def make_ts(day, hour, minute=0):
    """Create a unix timestamp for a given day offset and time."""
    base = datetime(2026, 4, 20) + timedelta(days=day)
    dt = base.replace(hour=hour, minute=minute)
    return int(dt.timestamp())


def write_session(session_id, events):
    """Write events to a session file."""
    path = SESSIONS_DIR / f"{session_id}.jsonl"
    with path.open("w") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")
    return path


def read_daily(day_str):
    """Read all entries from a daily log file."""
    path = DAILY_DIR / f"{day_str}.jsonl"
    if not path.exists():
        return []
    entries = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            entries.append(json.loads(line))
    return entries


def clear_daily():
    """Remove all daily log files."""
    for f in DAILY_DIR.glob("*.jsonl"):
        f.unlink()


def assert_eq(label, actual, expected):
    global passed, failed
    if actual == expected:
        passed += 1
        print(f"  PASS: {label}")
    else:
        failed += 1
        print(f"  FAIL: {label}")
        print(f"    expected: {expected}")
        print(f"    actual:   {actual}")


# ---------------------------------------------------------------------------
# Import session-end logic directly (with patched paths)
# ---------------------------------------------------------------------------
# We'll inline the core functions to test them in isolation.

from collections import defaultdict
import re

IDLE_THRESHOLD = 30 * 60

def compute_active_intervals(timestamps, idle_threshold):
    if not timestamps:
        return []
    if len(timestamps) == 1:
        return [(timestamps[0], timestamps[0] + 60)]
    intervals = []
    interval_start = timestamps[0]
    prev = timestamps[0]
    for ts in timestamps[1:]:
        if ts - prev > idle_threshold:
            intervals.append((interval_start, prev))
            interval_start = ts
        prev = ts
    intervals.append((interval_start, prev))
    return intervals


def split_by_day(intervals):
    per_day = defaultdict(int)
    for start, end in intervals:
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


# ===========================================================================
print("=" * 60)
print("Test 1: Simple session — no breaks")
print("=" * 60)
# User sends 3 prompts over 45 minutes, no breaks
clear_daily()
ts = [
    make_ts(0, 10, 0),   # 10:00
    make_ts(0, 10, 15),  # 10:15
    make_ts(0, 10, 45),  # 10:45
]
intervals = compute_active_intervals(ts, IDLE_THRESHOLD)
day_seconds = split_by_day(intervals)

assert_eq("single interval", len(intervals), 1)
assert_eq("active time = 45 min", intervals[0][1] - intervals[0][0], 45 * 60)
assert_eq("single day", list(day_seconds.keys()), ["2026-04-20"])
assert_eq("day seconds = 2700", day_seconds["2026-04-20"], 2700)


# ===========================================================================
print()
print("=" * 60)
print("Test 2: Session with a 2-hour break")
print("=" * 60)
# Work 10:00-10:50 (gaps of 25 min, under 30-min threshold), break, resume 13:00-13:50
ts = [
    make_ts(0, 10, 0),   # 10:00
    make_ts(0, 10, 25),  # 10:25 (+25 min, under threshold)
    make_ts(0, 10, 50),  # 10:50 (+25 min, under threshold)
    # -- 2h10m break (over threshold) --
    make_ts(0, 13, 0),   # 13:00
    make_ts(0, 13, 25),  # 13:25 (+25 min, under threshold)
    make_ts(0, 13, 50),  # 13:50 (+25 min, under threshold)
]
intervals = compute_active_intervals(ts, IDLE_THRESHOLD)
day_seconds = split_by_day(intervals)

assert_eq("two intervals (break detected)", len(intervals), 2)
assert_eq("first interval = 50 min", (intervals[0][1] - intervals[0][0]) // 60, 50)
assert_eq("second interval = 50 min", (intervals[1][1] - intervals[1][0]) // 60, 50)
assert_eq("total active = 100 min", day_seconds["2026-04-20"] // 60, 100)


# ===========================================================================
print()
print("=" * 60)
print("Test 3: Session spanning midnight")
print("=" * 60)
# Work 23:00 day 0 to 01:00 day 1 (continuous, no break)
ts = [
    make_ts(0, 23, 0),   # 23:00 day 0
    make_ts(0, 23, 20),  # 23:20
    make_ts(0, 23, 50),  # 23:50
    make_ts(1, 0, 10),   # 00:10 day 1
    make_ts(1, 0, 30),   # 00:30
    make_ts(1, 1, 0),    # 01:00
]
intervals = compute_active_intervals(ts, IDLE_THRESHOLD)
day_seconds = split_by_day(intervals)

assert_eq("single interval (no break)", len(intervals), 1)
assert_eq("spans two days", len(day_seconds), 2)
assert_eq("day 0 has time", "2026-04-20" in day_seconds, True)
assert_eq("day 1 has time", "2026-04-21" in day_seconds, True)
day0_min = day_seconds["2026-04-20"] // 60
day1_min = day_seconds["2026-04-21"] // 60
assert_eq("day 0 ~ 60 min", day0_min, 60)
assert_eq("day 1 ~ 60 min", day1_min, 60)
assert_eq("total ~ 120 min", day0_min + day1_min, 120)


# ===========================================================================
print()
print("=" * 60)
print("Test 4: Session left open overnight (should detect break)")
print("=" * 60)
# Work 16:00-17:00, left open, next activity at 09:00 next day
ts = [
    make_ts(0, 16, 0),
    make_ts(0, 16, 30),
    make_ts(0, 17, 0),
    # -- overnight gap (16 hours) --
    make_ts(1, 9, 0),
    make_ts(1, 9, 30),
    make_ts(1, 10, 0),
]
intervals = compute_active_intervals(ts, IDLE_THRESHOLD)
day_seconds = split_by_day(intervals)

assert_eq("two intervals (overnight break)", len(intervals), 2)
assert_eq("day 0 ~ 60 min", day_seconds.get("2026-04-20", 0) // 60, 60)
assert_eq("day 1 ~ 60 min", day_seconds.get("2026-04-21", 0) // 60, 60)
assert_eq("total ~ 120 min (not 17 hours)", sum(day_seconds.values()) // 60, 120)


# ===========================================================================
print()
print("=" * 60)
print("Test 5: Single event session")
print("=" * 60)
ts = [make_ts(0, 14, 0)]
intervals = compute_active_intervals(ts, IDLE_THRESHOLD)
day_seconds = split_by_day(intervals)

assert_eq("single interval", len(intervals), 1)
assert_eq("minimum 1 min", day_seconds["2026-04-20"] // 60, 1)


# ===========================================================================
print()
print("=" * 60)
print("Test 6: Multiple short breaks (under threshold)")
print("=" * 60)
# 10 min work, 25 min gap (under 30), 10 min work, 25 min gap, 10 min work
ts = [
    make_ts(0, 10, 0),
    make_ts(0, 10, 10),  # +10 min
    # 25 min gap (under threshold)
    make_ts(0, 10, 35),
    make_ts(0, 10, 45),  # +10 min
    # 25 min gap (under threshold)
    make_ts(0, 11, 10),
    make_ts(0, 11, 20),  # +10 min
]
intervals = compute_active_intervals(ts, IDLE_THRESHOLD)
day_seconds = split_by_day(intervals)

assert_eq("single interval (gaps under threshold)", len(intervals), 1)
assert_eq("total = 80 min (includes gaps)", (intervals[0][1] - intervals[0][0]) // 60, 80)


# ===========================================================================
print()
print("=" * 60)
print("Test 7: Ticket extraction from prompt events")
print("=" * 60)

TICKET_RE = re.compile(r"\b(AB-\d+)\b", re.IGNORECASE)

test_prompts = [
    ("AB-12343 fix the auth bug", "AB-12343"),
    ("focus on AB-12405\n\ncheck the migration", "AB-12405"),
    ("what is the weather today", None),
    ("PROJ-99 and AB-100 both need work", "AB-100"),  # only AB- keys count
    ("convert to UTF-8 and check M-1 sizing", None),  # false-positive guard
    ("", None),
]

for prompt, expected in test_prompts:
    m = TICKET_RE.search(prompt)
    actual = m.group(1) if m else None
    assert_eq(f"ticket from '{prompt[:40]}'", actual, expected)


# ===========================================================================
print()
print("=" * 60)
print("Test 8: track-prompt.sh integration")
print("=" * 60)
# Run the actual track-prompt.sh script and verify its output

test_session_id = "test-prompt-hook-001"
env = os.environ.copy()

# Clean up any leftover from previous run
real_path = Path.home() / ".claude" / "timelog" / "sessions" / f"{test_session_id}.jsonl"
if real_path.exists():
    real_path.unlink()

# Build the input JSON that UserPromptSubmit provides
hook_input = json.dumps({
    "session_id": test_session_id,
    "prompt": "AB-12345 investigate the login flow",
})

result = subprocess.run(
    ["bash", str(TRACK_PROMPT)],
    input=hook_input,
    capture_output=True,
    text=True,
    env=env,
)

if real_path.exists():
    lines = [l for l in real_path.read_text().strip().split("\n") if l.strip()]
    entry = json.loads(lines[-1])
    assert_eq("prompt event written", entry.get("event"), "prompt")
    assert_eq("ticket extracted", entry.get("ticket"), "AB-12345")
    assert_eq("meta is false", entry.get("meta"), False)
    assert_eq("has timestamp", "ts" in entry, True)
    real_path.unlink()
else:
    failed += 1
    print(f"  FAIL: track-prompt.sh produced no output")
    if result.stderr:
        print(f"    stderr: {result.stderr}")


# ===========================================================================
print()
print("=" * 60)
print("Test 9: Meta session detection via prompt")
print("=" * 60)

test_session_id2 = "test-prompt-hook-002"
hook_input_meta = json.dumps({
    "session_id": test_session_id2,
    "prompt": "submit-times for this week",
})
result2 = subprocess.run(
    ["bash", str(TRACK_PROMPT)],
    input=hook_input_meta,
    capture_output=True,
    text=True,
    env=env,
)

real_path2 = Path.home() / ".claude" / "timelog" / "sessions" / f"{test_session_id2}.jsonl"

if real_path2.exists():
    lines = [l for l in real_path2.read_text().strip().split("\n") if l.strip()]
    if lines:
        entry = json.loads(lines[-1])
        assert_eq("meta detected", entry.get("meta"), True)
        assert_eq("ticket empty for meta", entry.get("ticket"), "")
    else:
        failed += 1
        print("  FAIL: meta session file is empty")
    real_path2.unlink()
else:
    failed += 1
    print(f"  FAIL: track-prompt.sh meta test produced no output")
    if result2.stderr:
        print(f"    stderr: {result2.stderr}")


# ===========================================================================
print()
print("=" * 60)
print("Test 10: ignoretime opt-out via track-prompt.sh")
print("=" * 60)

test_session_id3 = "test-prompt-hook-003"
real_path3 = Path.home() / ".claude" / "timelog" / "sessions" / f"{test_session_id3}.jsonl"
if real_path3.exists():
    real_path3.unlink()

hook_input_ignore = json.dumps({
    "session_id": test_session_id3,
    "prompt": "ignoretime — quick question about zsh",
})
subprocess.run(["bash", str(TRACK_PROMPT)], input=hook_input_ignore,
               capture_output=True, text=True, env=env)

if real_path3.exists():
    events = [json.loads(l) for l in real_path3.read_text().strip().split("\n") if l.strip()]
    assert_eq("ignore event written", any(e.get("event") == "ignore" for e in events), True)
    assert_eq("prompt event also written", any(e.get("event") == "prompt" for e in events), True)
    real_path3.unlink()
else:
    failed += 1
    print("  FAIL: ignoretime test produced no output")


# ===========================================================================
print()
print("=" * 60)
print("Test 11: session-end.sh integration — categories, upsert idempotency")
print("=" * 60)
# Run the real session-end.sh in a fake HOME so Path.home() resolves there.

fake_home = Path(tempfile.mkdtemp(prefix="timelog-home-"))
fake_sessions = fake_home / ".claude" / "timelog" / "sessions"
fake_daily = fake_home / ".claude" / "timelog" / "daily"
fake_sessions.mkdir(parents=True)
fake_daily.mkdir(parents=True)

se_env = os.environ.copy()
se_env["HOME"] = str(fake_home)
se_env["TIMELOG_NO_DIALOG"] = "1"  # never pop dialogs from tests


def run_session_end_real(session_id):
    return subprocess.run(
        ["python3", str(SESSION_END)],
        input=json.dumps({"session_id": session_id}),
        capture_output=True, text=True, env=se_env,
    )


def write_fake_session(session_id, events):
    path = fake_sessions / f"{session_id}.jsonl"
    with path.open("w") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")


def read_fake_daily(day_str):
    path = fake_daily / f"{day_str}.jsonl"
    if not path.exists():
        return []
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


day0 = datetime(2026, 4, 20).strftime("%Y-%m-%d")

# 11a: work session with edits + ticket
write_fake_session("sess-work", [
    {"ts": make_ts(0, 10, 0), "event": "start", "cwd": "/tmp"},
    {"ts": make_ts(0, 10, 5), "event": "prompt", "ticket": "AB-100", "meta": False},
    {"ts": make_ts(0, 10, 30), "repo": "nest-api", "ticket": "AB-100", "file": "a.ts"},
    {"ts": make_ts(0, 11, 0), "repo": "nest-api", "ticket": "AB-100", "file": "b.ts"},
])
r = run_session_end_real("sess-work")
recs = read_fake_daily(day0)
assert_eq("work session: one record", len(recs), 1)
assert_eq("work session: category", recs[0]["category"] if recs else None, "work")
assert_eq("work session: ticket", recs[0]["ticket"] if recs else None, "AB-100")
assert_eq("work session: ~60 min", recs[0]["minutes"] if recs else 0, 60)

# 11b: re-fire SessionEnd — must NOT duplicate (the c956400b bug)
run_session_end_real("sess-work")
run_session_end_real("sess-work")
recs = read_fake_daily(day0)
assert_eq("re-fire: still one record (upsert)", len(recs), 1)

# 11c: ignoretime session -> meta
write_fake_session("sess-ignored", [
    {"ts": make_ts(0, 14, 0), "event": "start", "cwd": "/tmp"},
    {"ts": make_ts(0, 14, 0), "event": "ignore"},
    {"ts": make_ts(0, 14, 1), "event": "prompt", "ticket": "", "meta": False},
    {"ts": make_ts(0, 14, 40), "event": "prompt", "ticket": "", "meta": False},
])
run_session_end_real("sess-ignored")
recs = [r for r in read_fake_daily(day0) if r["session_id"] == "sess-ignored"]
assert_eq("ignored session: one record", len(recs), 1)
assert_eq("ignored session: category meta", recs[0]["category"] if recs else None, "meta")

# 11d: garbage ticket in old-format events normalizes to unknown
write_fake_session("sess-garbage", [
    {"ts": make_ts(0, 16, 0), "event": "start", "cwd": "/tmp"},
    {"ts": make_ts(0, 16, 5), "event": "prompt", "ticket": "M-1", "meta": False},
    {"ts": make_ts(0, 16, 30), "repo": "abler-web", "ticket": "H-4", "file": "x.js"},
])
run_session_end_real("sess-garbage")
recs = [r for r in read_fake_daily(day0) if r["session_id"] == "sess-garbage"]
assert_eq("garbage tickets: one merged unknown record", len(recs), 1)
assert_eq("garbage tickets: ticket=unknown", recs[0]["ticket"] if recs else None, "unknown")

# 11e: upsert must not touch logged:true or other sessions' entries
daily_file = fake_daily / f"{day0}.jsonl"
existing = daily_file.read_text()
daily_file.write_text(
    json.dumps({"session_id": "sess-work", "date": day0, "ticket": "AB-100", "repos": ["nest-api"],
                "minutes": 30, "edit_count": 1, "description": "", "category": "work", "logged": True})
    + "\n" + existing
)
run_session_end_real("sess-work")
recs = read_fake_daily(day0)
logged_kept = [r for r in recs if r["session_id"] == "sess-work" and r.get("logged")]
unlogged = [r for r in recs if r["session_id"] == "sess-work" and not r.get("logged")]
others = [r for r in recs if r["session_id"] != "sess-work"]
assert_eq("upsert keeps logged:true entry", len(logged_kept), 1)
assert_eq("upsert: one fresh unlogged entry", len(unlogged), 1)
assert_eq("upsert leaves other sessions alone", len(others) >= 2, True)

# 11f: midnight-spanning session — signal-less day inherits dominant ticket
write_fake_session("sess-midnight", [
    {"ts": make_ts(0, 23, 0), "event": "start", "cwd": "/tmp"},
    {"ts": make_ts(0, 23, 10), "event": "prompt", "ticket": "AB-200", "meta": False},
    {"ts": make_ts(0, 23, 30), "repo": "nest-api", "ticket": "AB-200", "file": "a.ts"},
    {"ts": make_ts(1, 0, 10), "event": "prompt", "ticket": "", "meta": False},
    {"ts": make_ts(1, 0, 40), "event": "prompt", "ticket": "", "meta": False},
])
run_session_end_real("sess-midnight")
day1 = datetime(2026, 4, 21).strftime("%Y-%m-%d")
recs = [r for r in read_fake_daily(day1) if r["session_id"] == "sess-midnight"]
assert_eq("midnight spill: one record on day 2", len(recs), 1)
assert_eq("midnight spill: inherits ticket", recs[0]["ticket"] if recs else None, "AB-200")
assert_eq("midnight spill: inherits repos", recs[0]["repos"] if recs else None, ["nest-api"])

shutil_cleanup_dirs = [fake_home]


# ===========================================================================
print()
print("=" * 60)
print("Test 12: timelog-cli.py — list, day distribution, mark-logged")
print("=" * 60)

CLI = HOOKS_DIR / "timelog-cli.py"
cli_home = Path(tempfile.mkdtemp(prefix="timelog-cli-"))
cli_daily = cli_home / ".claude" / "timelog" / "daily"
cli_daily.mkdir(parents=True)
cli_env = os.environ.copy()
cli_env["HOME"] = str(cli_home)


def run_cli(*args):
    return subprocess.run(["python3", str(CLI), *args],
                          capture_output=True, text=True, env=cli_env)


day_file = cli_daily / "2026-04-20.jsonl"
day_file.write_text("\n".join(json.dumps(e) for e in [
    {"session_id": "s1", "date": "2026-04-20", "ticket": "AB-100", "repos": ["nest-api"],
     "minutes": 167, "edit_count": 10, "description": "Edited a.ts in nest-api",
     "category": "work", "logged": False},
    {"session_id": "s2", "date": "2026-04-20", "ticket": "AB-100", "repos": ["nest-api"],
     "minutes": 30, "edit_count": 2, "description": "", "category": "work", "logged": False},
    {"session_id": "s3", "date": "2026-04-20", "ticket": "unknown", "repos": [],
     "minutes": 3, "edit_count": 0, "description": "", "category": "work", "logged": False},
    {"session_id": "s4", "date": "2026-04-20", "ticket": "unknown", "repos": [],
     "minutes": 9, "edit_count": 0, "description": "", "category": "meta", "logged": False},
]) + "\n")

out = run_cli("list").stdout
assert_eq("list shows the day", "2026-04-20" in out, True)
assert_eq("list: 2 groups (meta excluded)", "(2 groups" in out, True)

out = run_cli("day", "2026-04-20", "--already", "120").stdout
js = json.loads(out.split("```json")[1].split("```")[0])
assert_eq("day: 2 groups in JSON", len(js), 2)
g1, g2 = js[0], js[1]
assert_eq("group 1 ticket", g1["ticket"], "AB-100")
# bucketing: 167+30=197 -> 195; unknown 3 -> 15; sum 210 < available 360 -> expand
assert_eq("fills available exactly", g1["allocated_min"] + g2["allocated_min"], 360)
assert_eq("allocations are 15-min buckets",
          g1["allocated_min"] % 15 == 0 and g2["allocated_min"] % 15 == 0, True)

# lock + skip: lock #1 to 240, skip #2 -> only group 1 at 240
out = run_cli("day", "2026-04-20", "--already", "120", "--lock", "1=240", "--skip", "2").stdout
js = json.loads(out.split("```json")[1].split("```")[0])
assert_eq("lock+skip: one group", len(js), 1)
assert_eq("lock honored", js[0]["allocated_min"], 240)

# mark-logged: AB-100 done -> file kept (unknown work remains)
out = run_cli("mark-logged", "2026-04-20", "--ticket", "AB-100", "--repos", "nest-api").stdout
assert_eq("mark-logged keeps file", "File kept" in out, True)
# unknown done -> only meta left -> file deleted
out = run_cli("mark-logged", "2026-04-20", "--ticket", "unknown", "--repos", "").stdout
assert_eq("mark-logged deletes file when work done", "file deleted" in out, True)
assert_eq("day file gone", day_file.exists(), False)


# ===========================================================================
# Cleanup
# ===========================================================================
import shutil
shutil.rmtree(TIMELOG_BASE, ignore_errors=True)
shutil.rmtree(fake_home, ignore_errors=True)
shutil.rmtree(cli_home, ignore_errors=True)
try:
    TIMELOG_BASE.parent.rmdir()
except OSError:
    pass

# ===========================================================================
# Summary
# ===========================================================================
print()
print("=" * 60)
total = passed + failed
print(f"Results: {passed}/{total} passed, {failed} failed")
print("=" * 60)

sys.exit(1 if failed else 0)
