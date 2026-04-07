#!/bin/bash
# claude-sessions-board: SessionEnd hook (best-effort cleanup)
# Note: SessionEnd is NOT called on kill -9 / crash. TTL+GC is the source of truth.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)

if [ -z "$SESSION_ID" ] || [ -z "$CWD" ]; then
  exit 0
fi

BOARD=~/.claude/bin/sessions-board
[ ! -x "$BOARD" ] && exit 0

"$BOARD" --cwd "$CWD" unregister --session-id "$SESSION_ID" >/dev/null 2>&1
exit 0
