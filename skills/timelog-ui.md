---
description: Launch the local timelog review UI (drag to adjust times, edit tickets) in the browser
---

Start the timelog review server and open it in the browser:

```bash
pgrep -f timelog-server.py >/dev/null || (nohup python3 ~/.claude/timelog/app/timelog-server.py >/dev/null 2>&1 & sleep 0.5)
open http://localhost:8377
```

Then tell the user: "Timelog UI open at http://localhost:8377. Drag bars to set times (saved as 🔒 locks that /submit-times honors), click tickets to rename, 🚫 marks a row not-work. Stop the server with: pkill -f timelog-server.py"

Nothing else to do — all edits save instantly from the browser.
