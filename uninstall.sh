#!/bin/bash
# claude-sessions-board uninstaller
# Removes the CLI, hook scripts, settings.json entries, and (optionally) state.

set -e

DRY_RUN=0
PURGE_STATE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --purge-state) PURGE_STATE=1 ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [--dry-run] [--purge-state]"
      echo "  --dry-run       show what would happen, change nothing"
      echo "  --purge-state   also delete ~/.claude/coordination/ (board state)"
      exit 0
      ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

say() { echo "[uninstall] $*"; }
do_or_show() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  (dry-run) $*"
  else
    eval "$@"
  fi
}

say "removing CLI and hook scripts"
for f in \
  "$CLAUDE_DIR/bin/sessions-board" \
  "$CLAUDE_DIR/hooks/session-start-board.sh" \
  "$CLAUDE_DIR/hooks/user-prompt-submit-board.sh" \
  "$CLAUDE_DIR/hooks/pre-tool-use-board.sh" \
  "$CLAUDE_DIR/hooks/session-end-board.sh"; do
  if [ -e "$f" ]; then
    do_or_show "rm '$f'"
  fi
done

if [ -f "$SETTINGS" ]; then
  say "stripping hook entries from $SETTINGS"
  BACKUP="$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
  if [ "$DRY_RUN" -ne 1 ]; then
    cp "$SETTINGS" "$BACKUP"
    say "  backup: $BACKUP"
  fi
  PY=$(cat <<'PYEOF'
import json, sys

settings_path = sys.argv[1]
dry_run = sys.argv[2] == "1"

with open(settings_path) as f:
    settings = json.load(f)

OUR_COMMANDS = {
    "~/.claude/hooks/session-start-board.sh",
    "~/.claude/hooks/user-prompt-submit-board.sh",
    "~/.claude/hooks/pre-tool-use-board.sh",
    "~/.claude/hooks/session-end-board.sh",
}

removed = 0
hooks = settings.get("hooks", {})
for event, groups in list(hooks.items()):
    for g in groups:
        before = len(g.get("hooks", []))
        g["hooks"] = [h for h in g.get("hooks", []) if h.get("command") not in OUR_COMMANDS]
        removed += before - len(g["hooks"])
    hooks[event] = [g for g in groups if g.get("hooks")]
    if not hooks[event]:
        del hooks[event]
if not hooks:
    settings.pop("hooks", None)

if dry_run:
    print(f"  (dry-run) would remove {removed} hook entries")
else:
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"  removed {removed} hook entries")
PYEOF
)
  python3 -c "$PY" "$SETTINGS" "$DRY_RUN"
fi

if [ "$PURGE_STATE" -eq 1 ]; then
  say "purging board state at $CLAUDE_DIR/coordination/"
  do_or_show "rm -rf '$CLAUDE_DIR/coordination'"
fi

say "done."
