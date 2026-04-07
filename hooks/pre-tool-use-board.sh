#!/bin/bash
# claude-sessions-board: PreToolUse hook for Edit/Write/MultiEdit/NotebookEdit
# Denies the edit if the target file is locked by another active session.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
TOOL=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null)

case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

if [ -z "$SESSION_ID" ] || [ -z "$CWD" ] || [ -z "$FILE_PATH" ]; then
  exit 0
fi

BOARD=~/.claude/bin/sessions-board
[ ! -x "$BOARD" ] && exit 0

REASON=$("$BOARD" --cwd "$CWD" check-lock "$FILE_PATH" --session-id "$SESSION_ID" 2>&1 >/dev/null)
EXIT=$?

if [ $EXIT -eq 2 ] && [ -n "$REASON" ]; then
  python3 -c "
import json, sys
reason = sys.stdin.read().strip()
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'PreToolUse',
    'permissionDecision': 'deny',
    'permissionDecisionReason': reason
  }
}))
" <<EOF
${REASON}
EOF
  exit 0
fi

exit 0
