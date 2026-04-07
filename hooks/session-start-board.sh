#!/bin/bash
# claude-sessions-board: SessionStart hook
# Registers this session, then surfaces other sessions and unread messages.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)

if [ -z "$SESSION_ID" ] || [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  echo '{}'
  exit 0
fi

BOARD=~/.claude/bin/sessions-board
if [ ! -x "$BOARD" ]; then
  echo '{}'
  exit 0
fi

BRANCH=""
if (cd "$CWD" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
  BRANCH=$(cd "$CWD" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
fi

"$BOARD" --cwd "$CWD" register --session-id "$SESSION_ID" --pid "$PPID" --branch "$BRANCH" >/dev/null 2>&1

LIST_OUT=$("$BOARD" --cwd "$CWD" list --session-id "$SESSION_ID" 2>/dev/null)
INBOX_OUT=$("$BOARD" --cwd "$CWD" inbox --session-id "$SESSION_ID" --quiet 2>/dev/null)

MSG="[Sessions Board] registered as session_id=${SESSION_ID:0:12}"
if [ -n "$LIST_OUT" ]; then
  MSG="${MSG}

${LIST_OUT}"
fi
if [ -n "$INBOX_OUT" ]; then
  MSG="${MSG}

${INBOX_OUT}"
fi

MSG="${MSG}

== sessions-board usage ==
- Declare what you're doing: sessions-board summary \"<one-line>\"
- See other sessions:        sessions-board list
- Lock a file:               sessions-board lock <path>
- Send a message:            sessions-board send <session_id> \"<text>\"
- Read your inbox:           sessions-board inbox

After the user tells you the task, immediately declare a summary so other sessions know what you're up to."

python3 -c "
import json, sys
msg = sys.stdin.read()
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'SessionStart',
    'additionalContext': msg
  }
}))
" <<EOF 2>/dev/null || echo '{}'
${MSG}
EOF
