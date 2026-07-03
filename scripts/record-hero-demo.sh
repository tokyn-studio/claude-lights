#!/usr/bin/env bash
#
# Choreographs three named fake sessions for recording the README hero GIF.
#
# Run it FROM the terminal window you want the click-to-focus shot to land
# in — the hook helper captures this terminal's identity, so clicking the
# demo sessions in the panel brings THIS window to the front.
#
# Usage: start your screen recording, then:  scripts/record-hero-demo.sh
# Timeline (~16s): working -> API needs input (red + badge + notification)
# -> resumed -> all done -> cleanup.

set -euo pipefail

HOOK="$HOME/Library/Application Support/ClaudeLights/claudelights-hook"
LABELS="$HOME/.claude/claudelights-labels.json"
[ -x "$HOOK" ] || { echo "Helper not installed — open ClaudeLights and install hooks first." >&2; exit 1; }

S1="demo-hero-frontend"
S2="demo-hero-api"
S3="demo-hero-docs"

emit() { # emit <session-id> <cwd> <verb>
  printf '{"session_id":"%s","cwd":"%s"}' "$1" "$2" | "$HOOK" "$3"
}

label() { # label <session-id> <name>
  python3 - "$LABELS" "$1" "$2" <<'PY'
import json, sys, os
path, sid, name = sys.argv[1:4]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data[sid] = name
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
}

cleanup() {
  for s in "$S1" "$S2" "$S3"; do emit "$s" /tmp remove; done
  python3 - "$LABELS" <<'PY'
import json, sys, os
path = sys.argv[1]
if os.path.exists(path):
    try:
        data = json.load(open(path))
        for key in [k for k in data if k.startswith("demo-hero-")]:
            del data[key]
        json.dump(data, open(path, "w"), indent=2, sort_keys=True)
    except Exception:
        pass
PY
}
trap cleanup EXIT

echo "Act 1 — calm: three sessions, two working, one done"
label "$S1" "Frontend"
label "$S2" "API server"
label "$S3" "Docs"
emit "$S1" "$HOME/projects/frontend" working
emit "$S2" "$HOME/projects/api" working
emit "$S3" "$HOME/projects/docs" done
sleep 5

echo "Act 2 — alarm: API server needs input (red icon, badge, notification)"
emit "$S2" "$HOME/projects/api" needs_input
sleep 6
echo "         (open the panel now, click the red row for the focus shot)"
sleep 4

echo "Act 3 — resolved: back to work, then all green"
emit "$S2" "$HOME/projects/api" resume
sleep 3
emit "$S1" "$HOME/projects/frontend" done
emit "$S2" "$HOME/projects/api" done
sleep 4

echo "Done — cleaning up demo sessions."
