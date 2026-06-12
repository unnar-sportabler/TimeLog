#!/usr/bin/env python3
"""
CLI for the timelog system — does all deterministic work for /submit-times
so the model only orchestrates and displays.

Commands:
  list
      Day picker: days with unsubmitted work groups.

  day <YYYY-MM-DD> [--target 480] [--already 0]
      [--skip N ...] [--lock N=MIN ...] [--set-ticket N=AB-123 ...]
      Grouped table with 15-min bucketing and proportional fill of the
      remaining time. Prints a markdown table followed by a JSON block.
      Group indices are stable (sorted by raw minutes desc, then ticket).

  mark-logged <YYYY-MM-DD> --ticket <ORIGINAL_TICKET> [--repos a,b]
      Set logged:true on all unlogged entries matching the ORIGINAL ticket
      (+ repos when given). Deletes the day file when no unlogged work
      entries remain. Prints what happened.

  missing-titles
      Ticket keys present in daily files but absent from the title cache
      (~/.claude/timelog/tickets.json). One key per line.

  set-titles
      Read a JSON object {"AB-123": "Issue summary", ...} from stdin and
      merge it into the title cache.
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

DAILY = Path.home() / ".claude" / "timelog" / "daily"
TITLES = Path.home() / ".claude" / "timelog" / "tickets.json"
OVERRIDES = Path.home() / ".claude" / "timelog" / "overrides"
TITLE_MAX = 45


def load_overrides(date):
    """Per-day UI overrides: {"target": 480, "locks": {"<ticket>|<repos,joined>": minutes}}."""
    try:
        return json.loads((OVERRIDES / f"{date}.json").read_text())
    except Exception:
        return {}


def group_key(ticket, repos):
    return f"{ticket}|{','.join(sorted(repos))}"


def load_titles():
    try:
        return json.loads(TITLES.read_text())
    except Exception:
        return {}


def ticket_label(ticket, titles):
    if ticket == "unknown":
        return "⚠️ unknown"
    title = titles.get(ticket, "")
    if not title:
        return ticket
    if len(title) > TITLE_MAX:
        title = title[: TITLE_MAX - 1] + "…"
    return f"{ticket} — {title}"


def read_day(path):
    entries = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                entries.append(json.loads(line))
            except Exception:
                pass
    return entries


def unsubmitted_work(entries):
    return [
        e for e in entries
        if not e.get("logged") and e.get("category", "work") != "meta"
    ]


def fmt_time(minutes):
    h, m = divmod(int(minutes), 60)
    if h and m:
        return f"{h}h {m}m"
    if h:
        return f"{h}h"
    return f"{m}m"


def build_groups(entries):
    """Group unsubmitted work entries by (ticket, repos). Stable order."""
    groups = defaultdict(lambda: {"minutes": 0, "edit_count": 0, "sessions": 0, "descriptions": []})
    for e in unsubmitted_work(entries):
        key = (e.get("ticket", "unknown"), tuple(sorted(e.get("repos", []))))
        g = groups[key]
        g["minutes"] += e.get("minutes", 0)
        g["edit_count"] += e.get("edit_count", 0)
        g["sessions"] += 1
        if e.get("description"):
            g["descriptions"].append(e["description"])
    result = []
    for (ticket, repos), g in groups.items():
        result.append({
            "ticket": ticket,
            "repos": list(repos),
            "raw_minutes": g["minutes"],
            "edit_count": g["edit_count"],
            "sessions": g["sessions"],
            "descriptions": g["descriptions"][:3],
        })
    result.sort(key=lambda g: (-g["raw_minutes"], g["ticket"]))
    return result


def bucket(raw_min):
    return max(15, (raw_min // 15) * 15)


def distribute(groups, target, already, locks):
    """Set bucketed/allocated minutes on each group. locks: {index: minutes}."""
    for g in groups:
        g["bucketed_min"] = bucket(g["raw_minutes"])

    available = max(0, target - already)
    locked_total = sum(locks.values())
    unlocked = [i for i in range(len(groups)) if i not in locks]
    sum_bucketed_unlocked = sum(groups[i]["bucketed_min"] for i in unlocked)
    remaining = max(0, available - locked_total)

    for i, g in enumerate(groups):
        if i in locks:
            g["allocated_min"] = locks[i]
        elif remaining <= 0 or sum_bucketed_unlocked >= remaining or sum_bucketed_unlocked == 0:
            g["allocated_min"] = g["bucketed_min"]
        else:
            proportional = g["bucketed_min"] / sum_bucketed_unlocked * remaining
            g["allocated_min"] = max(15, round(proportional / 15) * 15)

    # Fix rounding drift on the largest unlocked group (only when expanding to fill)
    if unlocked and 0 < sum_bucketed_unlocked < remaining:
        delta = remaining - sum(groups[i]["allocated_min"] for i in unlocked)
        if delta:
            big = max(unlocked, key=lambda i: groups[i]["allocated_min"])
            groups[big]["allocated_min"] = max(15, groups[big]["allocated_min"] + delta)

    sum_bucketed = sum(g["bucketed_min"] for g in groups)
    for g in groups:
        g["share_pct"] = round(g["bucketed_min"] / sum_bucketed * 100) if sum_bucketed else 0
    return available


def cmd_list(_args):
    days = []
    for path in sorted(DAILY.glob("*.jsonl"), reverse=True):
        groups = build_groups(read_day(path))
        if groups:
            tickets = list(dict.fromkeys(g["ticket"] for g in groups))
            shown = ["⚠️ unknown" if t == "unknown" else t for t in tickets[:3]]
            if len(tickets) > 3:
                shown.append("…")
            total = sum(g["raw_minutes"] for g in groups)
            days.append((path.stem, len(groups), fmt_time(total), ", ".join(shown)))
    if not days:
        print("No unsubmitted time entries found.")
        return
    print("Unsubmitted days:")
    for i, (day, n, total, tickets) in enumerate(days, 1):
        plural = "groups" if n != 1 else "group"
        print(f"{i}. {day}  ({n} {plural} · {total})  {tickets}")
    print()
    print('Pick a day (1, 2, …) or "all" to submit everything:')


def parse_kv(pairs, cast):
    out = {}
    for p in pairs or []:
        k, v = p.split("=", 1)
        out[int(k) - 1] = cast(v)  # 1-based on the CLI, 0-based internally
    return out


def cmd_day(args):
    path = DAILY / f"{args.date}.jsonl"
    if not path.exists():
        print(f"No log file for {args.date}.")
        sys.exit(1)
    groups = build_groups(read_day(path))
    if not groups:
        print(f"No unsubmitted work entries for {args.date}.")
        sys.exit(1)

    overrides = parse_kv(args.set_ticket, str)
    for i, t in overrides.items():
        if 0 <= i < len(groups):
            groups[i]["original_ticket"] = groups[i]["ticket"]
            groups[i]["ticket"] = t.upper()
    for g in groups:
        g.setdefault("original_ticket", g["ticket"])

    skips = {int(n) - 1 for n in args.skip or []}
    kept, skipped = [], []
    for i, g in enumerate(groups):
        (skipped if i in skips else kept).append((i, g))
    # locks/indices refer to the ORIGINAL numbering so they stay stable across re-runs
    locks_orig = parse_kv(args.lock, int)
    # UI overrides (drag-edited times); explicit CLI flags win on conflict
    ov = load_overrides(args.date)
    ov_locks = ov.get("locks", {})
    for i, g in enumerate(groups):
        key = group_key(g["original_ticket"], g["repos"])
        if key in ov_locks:
            locks_orig.setdefault(i, int(ov_locks[key]))
    target = args.target if args.target is not None else int(ov.get("target", 480))
    # UI "auto-fill off" — an explicit --target on the CLI re-enables filling
    fill = ov.get("fill", True) or args.target is not None
    kept_groups = [g for _, g in kept]
    locks = {pos: m for pos, (i, _) in enumerate(kept) for oi, m in locks_orig.items() if oi == i}

    available = distribute(kept_groups, target if fill else 0,
                           args.already if fill else 0, locks)

    print(f"Already logged in Tempo: {fmt_time(args.already)}  |  "
          f"Target: {fmt_time(target)}  |  Remaining to fill: {fmt_time(available)}")
    if not fill:
        print("ℹ️ Auto-fill disabled for this day (set in UI) — bucketed/pinned times only.")
    if args.already >= target:
        print("⚠️ Target already met or exceeded via existing Tempo logs. Entries will use bucketed times only.")
    print()
    titles = load_titles()
    print(f"### {args.date}")
    print("| # | Ticket | Repos | Bucketed | Allocated | Share | Edits | Sessions |")
    print("|---|--------|-------|----------|-----------|-------|-------|----------|")
    for i, g in kept:
        ticket = ticket_label(g["ticket"], titles)
        repos = ", ".join(g["repos"]) or "(none)"
        lock_mark = " 🔒" if i in locks_orig else ""
        print(f"| {i + 1} | {ticket} | {repos} | {fmt_time(g['bucketed_min'])} | "
              f"{fmt_time(g['allocated_min'])}{lock_mark} | {g['share_pct']}% | "
              f"{g['edit_count']} | {g['sessions']} |")
    total_alloc = sum(g["allocated_min"] for g in kept_groups)
    print(f"\nTotal: {fmt_time(total_alloc)}  (filling {fmt_time(available)} remaining)")
    for i, g in skipped:
        print(f"(skipped #{i + 1}: {g['ticket']}, {fmt_time(g['raw_minutes'])})")

    payload = [
        {
            "index": i + 1,
            "ticket": g["ticket"],
            "original_ticket": g["original_ticket"],
            "repos": g["repos"],
            "allocated_min": g["allocated_min"],
            "timeSpentHours": round(g["allocated_min"] / 60, 4),
            "descriptions": g["descriptions"],
        }
        for i, g in kept
    ]
    print("\n```json")
    print(json.dumps(payload, indent=1))
    print("```")


def cmd_mark_logged(args):
    path = DAILY / f"{args.date}.jsonl"
    if not path.exists():
        print(f"No log file for {args.date}.")
        sys.exit(1)
    repos = sorted(r.strip() for r in args.repos.split(",") if r.strip()) if args.repos else []
    entries = read_day(path)
    marked = 0
    for e in entries:
        if e.get("logged") or e.get("category", "work") == "meta":
            continue
        if e.get("ticket") != args.ticket:
            continue
        if args.repos is not None and sorted(e.get("repos", [])) != repos:
            continue
        e["logged"] = True
        marked += 1
    if not marked:
        print(f"No matching unlogged entries for ticket {args.ticket}.")
        sys.exit(1)
    if unsubmitted_work(entries):
        path.write_text("\n".join(json.dumps(e) for e in entries) + "\n")
        print(f"Marked {marked} entries logged. File kept (unlogged work entries remain).")
    else:
        path.unlink()
        (OVERRIDES / f"{args.date}.json").unlink(missing_ok=True)
        print(f"Marked {marked} entries logged. No unlogged work entries left — file deleted.")


def cmd_missing_titles(_args):
    titles = load_titles()
    keys = set()
    for path in DAILY.glob("*.jsonl"):
        for e in unsubmitted_work(read_day(path)):
            t = e.get("ticket", "unknown")
            if t != "unknown" and t not in titles:
                keys.add(t)
    for k in sorted(keys):
        print(k)


def cmd_set_titles(_args):
    try:
        incoming = json.loads(sys.stdin.read())
        assert isinstance(incoming, dict)
    except Exception:
        print("Expected a JSON object on stdin.")
        sys.exit(1)
    titles = load_titles()
    titles.update({k.upper(): str(v) for k, v in incoming.items()})
    TITLES.write_text(json.dumps(titles, indent=1, ensure_ascii=False))
    print(f"Cached {len(incoming)} title(s). {len(titles)} total.")


def main():
    parser = argparse.ArgumentParser(prog="timelog-cli")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list")
    sub.add_parser("missing-titles")
    sub.add_parser("set-titles")

    p_day = sub.add_parser("day")
    p_day.add_argument("date")
    p_day.add_argument("--target", type=int, default=None)  # None -> per-day override or 480
    p_day.add_argument("--already", type=int, default=0)
    p_day.add_argument("--skip", action="append")
    p_day.add_argument("--lock", action="append", metavar="N=MIN")
    p_day.add_argument("--set-ticket", action="append", metavar="N=KEY")

    p_mark = sub.add_parser("mark-logged")
    p_mark.add_argument("date")
    p_mark.add_argument("--ticket", required=True)
    p_mark.add_argument("--repos", default=None)

    args = parser.parse_args()
    {
        "list": cmd_list,
        "day": cmd_day,
        "mark-logged": cmd_mark_logged,
        "missing-titles": cmd_missing_titles,
        "set-titles": cmd_set_titles,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
