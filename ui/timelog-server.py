#!/usr/bin/env python3
"""
Local review UI for the timelog. Serves a single-page app on localhost.

Run:  python3 timelog-server.py [--port 8377]
Then: open http://localhost:8377

Edits write straight to ~/.claude/timelog/daily/*.jsonl (ticket, category,
delete) and ~/.claude/timelog/overrides/<date>.json (drag-edited times,
target) — /submit-times picks both up automatically.
"""

import argparse
import base64
import importlib.util
import json
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("timelog_cli", HERE / "timelog-cli.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

UI_FILE = HERE / "timelog-ui.html"
CONFIG = Path.home() / ".claude" / "timelog" / "config.json"
PROJECTS = Path.home() / ".claude" / "projects"


def load_config():
    try:
        return json.loads(CONFIG.read_text())
    except Exception:
        return {}


CREDS = Path.home() / ".claude" / "timelog" / "jira-credentials"
TEMPO_BASE = "https://api.tempo.io/4"

_issue_ids = {}      # ticket key -> numeric Jira issue id
_account_id = None
_tempo_cache = {}    # date -> already-logged minutes (cleared on submit)


def load_creds():
    """JIRA_EMAIL / JIRA_TOKEN / TEMPO_TOKEN from the credentials file."""
    creds = {}
    if CREDS.exists():
        for line in CREDS.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                creds[k.strip()] = v.strip()
    return creds


def http_json(url, headers, payload=None, timeout=15):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={
        **headers, "Accept": "application/json",
        **({"Content-Type": "application/json"} if payload is not None else {}),
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or "{}")


def jira_get(path):
    c = load_creds()
    base = load_config().get("jira_base", "")
    if not (c.get("JIRA_EMAIL") and c.get("JIRA_TOKEN") and base):
        raise RuntimeError("Jira credentials missing")
    auth = base64.b64encode(f"{c['JIRA_EMAIL']}:{c['JIRA_TOKEN']}".encode()).decode()
    return http_json(base + path, {"Authorization": f"Basic {auth}"})


def tempo_call(path, payload=None):
    c = load_creds()
    if not c.get("TEMPO_TOKEN"):
        raise RuntimeError("TEMPO_TOKEN missing")
    return http_json(TEMPO_BASE + path,
                     {"Authorization": f"Bearer {c['TEMPO_TOKEN']}"}, payload)


def tempo_ready():
    c = load_creds()
    return bool(c.get("TEMPO_TOKEN") and c.get("JIRA_EMAIL") and c.get("JIRA_TOKEN"))


def resolve_issue_id(key):
    if key not in _issue_ids:
        _issue_ids[key] = int(jira_get(f"/rest/api/3/issue/{key}?fields=id")["id"])
    return _issue_ids[key]


def account_id():
    global _account_id
    if _account_id is None:
        _account_id = jira_get("/rest/api/3/myself")["accountId"]
    return _account_id


def tempo_logged_minutes(date):
    """Minutes already in Tempo for the date. Cached until a submit clears it."""
    if date not in _tempo_cache:
        res = tempo_call(f"/worklogs/user/{account_id()}?from={date}&to={date}&limit=1000")
        _tempo_cache[date] = round(sum(w.get("timeSpentSeconds", 0)
                                       for w in res.get("results", [])) / 60)
    return _tempo_cache[date]


def fetch_missing_titles(keys):
    """Batch-fetch Jira summaries via REST and persist to the title cache.

    Needs ~/.claude/timelog/jira-credentials (chmod 600):
      JIRA_EMAIL=you@abler.io
      JIRA_TOKEN=<api token from id.atlassian.com/manage-profile/security/api-tokens>
    Silently returns {} when credentials are absent — /submit-times then fills
    the cache via the Atlassian MCP instead.
    """
    if not keys or not CREDS.exists():
        return {}
    creds = {}
    for line in CREDS.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            creds[k.strip()] = v.strip()
    email, token = creds.get("JIRA_EMAIL"), creds.get("JIRA_TOKEN")
    base = load_config().get("jira_base", "")
    if not (email and token and base):
        return {}
    jql = f"key in ({','.join(keys)})"
    url = (f"{base}/rest/api/3/search/jql"
           f"?jql={urllib.parse.quote(jql)}&fields=summary&maxResults=100")
    auth = base64.b64encode(f"{email}:{token}".encode()).decode()
    req = urllib.request.Request(url, headers={
        "Authorization": f"Basic {auth}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read())
        found = {i["key"]: i["fields"]["summary"] for i in data.get("issues", [])
                 if i.get("fields", {}).get("summary")}
        if found:
            titles = cli.load_titles()
            titles.update(found)
            cli.TITLES.write_text(json.dumps(titles, indent=1, ensure_ascii=False))
        return found
    except Exception:
        return {}


def session_prompts(session_id, limit=3, max_len=300):
    """First user prompts from the session transcript, for review context."""
    if not session_id or "/" in session_id:
        return []
    prompts = []
    for path in PROJECTS.glob(f"*/{session_id}.jsonl"):
        try:
            with path.open() as f:
                for line in f:
                    if len(prompts) >= limit:
                        break
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("type") != "user":
                        continue
                    content = (rec.get("message") or {}).get("content")
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list):
                        text = " ".join(c.get("text", "") for c in content
                                        if isinstance(c, dict) and c.get("type") == "text")
                    else:
                        continue
                    text = text.strip()
                    if not text or text.startswith("<"):
                        continue
                    prompts.append(text[:max_len] + ("…" if len(text) > max_len else ""))
        except OSError:
            pass
        break
    return prompts


def save_overrides(date, ov):
    cli.OVERRIDES.mkdir(parents=True, exist_ok=True)
    path = cli.OVERRIDES / f"{date}.json"
    if not ov.get("locks") and not ov.get("target") and ov.get("fill", True):
        path.unlink(missing_ok=True)
    else:
        path.write_text(json.dumps(ov, indent=1))


def write_day(date, entries):
    path = cli.DAILY / f"{date}.jsonl"
    if entries:
        path.write_text("\n".join(json.dumps(e) for e in entries) + "\n")
    else:
        path.unlink(missing_ok=True)
        (cli.OVERRIDES / f"{date}.json").unlink(missing_ok=True)


def day_payload(date):
    path = cli.DAILY / f"{date}.jsonl"
    if not path.exists():
        return {"date": date, "groups": [], "meta": [], "target": 480, "locks": {}}
    entries = cli.read_day(path)
    groups = cli.build_groups(entries)
    ov = cli.load_overrides(date)
    target = int(ov.get("target", 480))
    fill = ov.get("fill", True)
    ov_locks = ov.get("locks", {})
    locks = {}
    for i, g in enumerate(groups):
        key = cli.group_key(g["ticket"], g["repos"])
        g["key"] = key
        if key in ov_locks:
            locks[i] = int(ov_locks[key])
    already = 0
    if fill and tempo_ready():
        try:
            already = tempo_logged_minutes(date)
        except Exception:
            already = 0
    # fill off -> available 0: locks honored, the rest stay at bucketed time
    cli.distribute(groups, target if fill else 0, already if fill else 0, locks)
    titles = cli.load_titles()
    missing = sorted({g["ticket"] for g in groups
                      if g["ticket"] != "unknown" and g["ticket"] not in titles})
    titles.update(fetch_missing_titles(missing))
    for g in groups:
        g["title"] = titles.get(g["ticket"], "")
        g["locked"] = g["key"] in ov_locks
        g["entries"] = [
            {"session_id": e.get("session_id", ""), "minutes": e.get("minutes", 0),
             "edit_count": e.get("edit_count", 0), "description": e.get("description", "")}
            for e in group_entries(entries, g["ticket"], g["repos"])
        ]
    meta = [
        {"minutes": e.get("minutes", 0), "description": e.get("description", ""),
         "ticket": e.get("ticket", "unknown"), "repos": e.get("repos", []),
         "session_id": e.get("session_id", "")}
        for e in entries
        if not e.get("logged") and e.get("category", "work") == "meta"
    ]
    return {"date": date, "groups": groups, "meta": meta, "target": target,
            "fill": fill, "locks": ov_locks, "already": already,
            "tempo_ready": tempo_ready(),
            "jira_base": load_config().get("jira_base", "")}


def days_payload():
    days = []
    for path in sorted(cli.DAILY.glob("*.jsonl"), reverse=True):
        groups = cli.build_groups(cli.read_day(path))
        if groups:
            days.append({
                "date": path.stem,
                "groups": len(groups),
                "minutes": sum(g["raw_minutes"] for g in groups),
                "unknown": any(g["ticket"] == "unknown" for g in groups),
            })
    return days


def group_entries(entries, ticket, repos):
    """Unlogged work entries belonging to a (ticket, repos) group."""
    repos = sorted(repos)
    return [
        e for e in cli.unsubmitted_work(entries)
        if e.get("ticket") == ticket and sorted(e.get("repos", [])) == repos
    ]


def mutate(date, body):
    path = cli.DAILY / f"{date}.jsonl"
    if not path.exists():
        return {"error": "day not found"}
    entries = cli.read_day(path)
    action = body.get("action")
    ticket = body.get("ticket")
    repos = body.get("repos", [])
    ov = cli.load_overrides(date)
    locks = ov.setdefault("locks", {})

    if action == "set_target":
        ov["target"] = max(15, int(body["target"]))
        save_overrides(date, ov)

    elif action == "set_fill":
        ov["fill"] = bool(body["fill"])
        save_overrides(date, ov)

    elif action == "set_lock":
        locks[cli.group_key(ticket, repos)] = max(15, int(body["minutes"]))
        save_overrides(date, ov)

    elif action == "clear_lock":
        locks.pop(cli.group_key(ticket, repos), None)
        save_overrides(date, ov)

    elif action == "set_ticket":
        new = body["new_ticket"].strip().upper()
        old_key = cli.group_key(ticket, repos)
        for e in group_entries(entries, ticket, repos):
            e["ticket"] = new
        if old_key in locks:  # carry the drag-lock over to the renamed group
            locks[cli.group_key(new, repos)] = locks.pop(old_key)
        write_day(date, entries)
        save_overrides(date, ov)

    elif action == "set_category":
        for e in group_entries(entries, ticket, repos):
            e["category"] = body["category"]
        if body["category"] == "meta":
            locks.pop(cli.group_key(ticket, repos), None)
        write_day(date, entries)
        save_overrides(date, ov)

    elif action == "restore_meta":
        sid = body.get("session_id")
        for e in entries:
            if (e.get("category") == "meta" and not e.get("logged")
                    and e.get("session_id") == sid):
                e["category"] = "work"
        write_day(date, entries)

    elif action == "delete_group":
        keep = []
        victims = {id(e) for e in group_entries(entries, ticket, repos)}
        for e in entries:
            if id(e) not in victims:
                keep.append(e)
        locks.pop(cli.group_key(ticket, repos), None)
        write_day(date, keep)
        save_overrides(date, ov)

    elif action == "set_entry_ticket":
        new = body["new_ticket"].strip().upper()
        sid = body["session_id"]
        for e in group_entries(entries, ticket, repos):
            if e.get("session_id") == sid:
                e["ticket"] = new
        write_day(date, entries)

    elif action == "delete_entry":
        sid = body["session_id"]
        victims = {id(e) for e in group_entries(entries, ticket, repos)
                   if e.get("session_id") == sid}
        write_day(date, [e for e in entries if id(e) not in victims])

    elif action == "add_suggestion":
        key = body["new_ticket"].strip().upper()
        minutes = max(15, int(body.get("minutes", 15)))
        entries.append({
            "session_id": f"suggestion-{key}",
            "date": date, "ticket": key, "repos": [],
            "minutes": minutes, "edit_count": 0,
            "description": "Jira activity", "category": "work", "logged": False,
        })
        write_day(date, entries)

    elif action == "delete_day":
        write_day(date, [])

    else:
        return {"error": f"unknown action {action}"}

    return day_payload(date)


_activity_cache = {}  # date -> [{ticket, title}]


def _day_event_count(key, date, me):
    """Number of changelog entries the user made on the issue that day."""
    res = jira_get(f"/rest/api/3/issue/{key}/changelog?maxResults=100")
    histories = res.get("values", [])
    total = res.get("total", 0)
    if total > 100:  # day's events are at the tail for long-lived issues
        res = jira_get(f"/rest/api/3/issue/{key}/changelog?startAt={total - 100}&maxResults=100")
        histories = res.get("values", [])
    return sum(1 for h in histories
               if h.get("author", {}).get("accountId") == me
               and h.get("created", "")[:10] == date)


def jira_activity(date):
    """Tickets the user touched in Jira that day (status changes, created) —
    rebuilds the Jira-sourced cards from Tempo's Activity Feed via plain JQL.
    Suggested minutes mirror Tempo's heuristic: ~15m per action, capped at 2h."""
    if date in _activity_cache:
        return _activity_cache[date]
    nxt = (datetime.strptime(date, "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d")
    jql = (f'(status CHANGED BY currentUser() DURING ("{date}", "{nxt}")) '
           f'OR (reporter = currentUser() AND created >= "{date}" AND created < "{nxt}")')
    res = jira_get("/rest/api/3/search/jql?jql=" + urllib.parse.quote(jql)
                   + "&fields=summary,created,reporter&maxResults=50")
    me = account_id()
    items = []
    for i in res.get("issues", []):
        f = i.get("fields", {})
        try:
            events = _day_event_count(i["key"], date, me)
        except Exception:
            events = 0
        if (f.get("reporter") or {}).get("accountId") == me and f.get("created", "")[:10] == date:
            events += 1  # creating the issue counts as an action
        items.append({"ticket": i["key"], "title": f.get("summary", ""),
                      "minutes": min(120, max(15, events * 15))})
    # remember the summaries for the main table too
    titles = cli.load_titles()
    fresh = {i["ticket"]: i["title"] for i in items if i["title"] and i["ticket"] not in titles}
    if fresh:
        titles.update(fresh)
        cli.TITLES.write_text(json.dumps(titles, indent=1, ensure_ascii=False))
    _activity_cache[date] = items
    return items


def activity_payload(date):
    c = load_creds()
    if not (c.get("JIRA_EMAIL") and c.get("JIRA_TOKEN")):
        return {"suggestions": [], "unavailable": "jira credentials not configured"}
    path = cli.DAILY / f"{date}.jsonl"
    have = set()
    if path.exists():
        have = {e.get("ticket") for e in cli.read_day(path) if not e.get("logged")}
    try:
        items = [i for i in jira_activity(date) if i["ticket"] not in have]
        return {"suggestions": items}
    except Exception as exc:
        return {"suggestions": [], "unavailable": str(exc)[:150]}


def settings_status():
    c = load_creds()
    return {
        "jira_email": c.get("JIRA_EMAIL", ""),
        "has_jira_token": bool(c.get("JIRA_TOKEN")),
        "has_tempo_token": bool(c.get("TEMPO_TOKEN")),
        "jira_base": load_config().get("jira_base", ""),
    }


def save_settings(body):
    global _account_id
    c = load_creds()
    if body.get("jira_email"):
        c["JIRA_EMAIL"] = body["jira_email"].strip()
    if body.get("jira_token"):
        c["JIRA_TOKEN"] = body["jira_token"].strip()
    if body.get("tempo_token"):
        c["TEMPO_TOKEN"] = body["tempo_token"].strip()
    CREDS.parent.mkdir(parents=True, exist_ok=True)
    CREDS.write_text("".join(f"{k}={v}\n" for k, v in c.items()))
    CREDS.chmod(0o600)
    _account_id = None
    _tempo_cache.clear()

    out = settings_status()
    try:
        me = jira_get("/rest/api/3/myself")
        out["jira_ok"] = True
        out["jira_user"] = me.get("displayName", "")
    except Exception as exc:
        out["jira_ok"] = False
        out["jira_error"] = str(exc)[:150]
    try:
        tempo_call("/worklogs?limit=1")
        out["tempo_ok"] = True
    except Exception as exc:
        out["tempo_ok"] = False
        out["tempo_error"] = str(exc)[:150]
    return out


def mark_group_logged(date, ticket, repos):
    path = cli.DAILY / f"{date}.jsonl"
    entries = cli.read_day(path)
    for e in group_entries(entries, ticket, repos):
        e["logged"] = True
    if cli.unsubmitted_work(entries):
        path.write_text("\n".join(json.dumps(e) for e in entries) + "\n")
    else:
        path.unlink(missing_ok=True)
        (cli.OVERRIDES / f"{date}.json").unlink(missing_ok=True)


def submit_day(date):
    if not tempo_ready():
        return {"error": "Tempo/Jira credentials not configured. See "
                         "~/.claude/timelog/jira-credentials (JIRA_EMAIL, "
                         "JIRA_TOKEN, TEMPO_TOKEN)."}
    payload = day_payload(date)
    groups = payload["groups"]
    if not groups:
        return {"error": "Nothing to submit."}
    if any(g["ticket"] == "unknown" for g in groups):
        return {"error": "Assign a ticket to every row first (or delete / mark "
                         "not-work the unknown ones)."}
    results = []
    for g in groups:
        repos = ", ".join(g["repos"])
        desc = f"Work on {g['ticket']} in {repos}" if repos else f"Work on {g['ticket']}"
        try:
            tempo_call("/worklogs", {
                "issueId": resolve_issue_id(g["ticket"]),
                "timeSpentSeconds": g["allocated_min"] * 60,
                "startDate": date,
                "description": desc,
                "authorAccountId": account_id(),
            })
            mark_group_logged(date, g["ticket"], g["repos"])
            results.append({"ticket": g["ticket"], "minutes": g["allocated_min"], "ok": True})
        except Exception as exc:
            results.append({"ticket": g["ticket"], "minutes": g["allocated_min"],
                            "ok": False, "error": str(exc)[:200]})
    _tempo_cache.pop(date, None)
    return {"results": results, "day": day_payload(date)}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, obj, status=200):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            data = UI_FILE.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store, must-revalidate")
            self.end_headers()
            self.wfile.write(data)
        elif self.path == "/logo.svg":
            data = (HERE / "timelog-logo.svg").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/svg+xml")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path in ("/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"):
            data = (HERE / "timelog-logo-180.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path == "/api/days":
            self.send_json(days_payload())
        elif self.path == "/api/settings":
            self.send_json(settings_status())
        elif self.path.startswith("/api/session/"):
            self.send_json({"prompts": session_prompts(self.path.rsplit("/", 1)[1])})
        elif self.path.startswith("/api/activity/"):
            self.send_json(activity_payload(self.path.rsplit("/", 1)[1]))
        elif self.path.startswith("/api/day/"):
            self.send_json(day_payload(self.path.rsplit("/", 1)[1]))
        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        if self.path == "/api/settings":
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(length))
            except Exception:
                self.send_json({"error": "bad json"}, 400)
                return
            self.send_json(save_settings(body))
            return
        if self.path.startswith("/api/submit/"):
            self.send_json(submit_day(self.path.rsplit("/", 1)[1]))
            return
        if not self.path.startswith("/api/day/"):
            self.send_json({"error": "not found"}, 404)
            return
        date = self.path.rsplit("/", 1)[1]
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length))
        except Exception:
            self.send_json({"error": "bad json"}, 400)
            return
        self.send_json(mutate(date, body))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8377)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Timelog UI on http://localhost:{args.port}  (Ctrl-C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
