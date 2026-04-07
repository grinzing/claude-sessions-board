#!/bin/bash
# claude-sessions-board: UserPromptSubmit hook
# Refreshes heartbeat (and triggers lazy GC) and surfaces unread messages.
# Kept lightweight; targets <100ms.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)

if [ -z "$SESSION_ID" ] || [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

BOARD=~/.claude/bin/sessions-board
[ ! -x "$BOARD" ] && exit 0

"$BOARD" --cwd "$CWD" heartbeat --session-id "$SESSION_ID" >/dev/null 2>&1

INBOX=$("$BOARD" --cwd "$CWD" inbox --session-id "$SESSION_ID" --quiet 2>/dev/null)

if [ -n "$INBOX" ]; then
  python3 -c "
import json, sys
msg = sys.stdin.read()
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'UserPromptSubmit',
    'additionalContext': '[Sessions Board: new messages]\n' + msg
  }
}))
" <<EOF 2>/dev/null
${INBOX}
EOF
fi

exit 0
