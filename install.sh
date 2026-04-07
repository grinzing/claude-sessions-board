#!/bin/bash
# claude-sessions-board installer
#
# What it does:
#   1. Copies bin/sessions-board to ~/.claude/bin/
#   2. Copies hooks/*.sh to ~/.claude/hooks/
#   3. Merges hook entries into ~/.claude/settings.json (with backup)
#
# Usage:
#   ./install.sh             # install
#   ./install.sh --dry-run   # show what would happen, change nothing
#   ./install.sh --force     # overwrite existing files without prompting
#
# Idempotent: re-running is safe. Skips already-installed hook entries.

set -e

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BIN_DIR="$CLAUDE_DIR/bin"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

say() { echo "[install] $*"; }
do_or_show() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  (dry-run) $*"
  else
    eval "$@"
  fi
}

if [ ! -d "$CLAUDE_DIR" ]; then
  say "ERROR: $CLAUDE_DIR not found. Is Claude Code installed?"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  say "ERROR: python3 is required."
  exit 1
fi

say "repo:     $REPO_DIR"
say "target:   $CLAUDE_DIR"
[ "$DRY_RUN" -eq 1 ] && say "mode:     DRY RUN (no changes)"

# 1. copy bin
say "step 1/3: copy bin/sessions-board -> $BIN_DIR/"
do_or_show "mkdir -p '$BIN_DIR'"
if [ -e "$BIN_DIR/sessions-board" ] && [ "$FORCE" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
  say "  $BIN_DIR/sessions-board already exists. Overwrite? [y/N]"
  read -r ans
  if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
    say "  skipped."
  else
    do_or_show "cp '$REPO_DIR/bin/sessions-board' '$BIN_DIR/sessions-board'"
    do_or_show "chmod +x '$BIN_DIR/sessions-board'"
  fi
else
  do_or_show "cp '$REPO_DIR/bin/sessions-board' '$BIN_DIR/sessions-board'"
  do_or_show "chmod +x '$BIN_DIR/sessions-board'"
fi

# 2. copy hooks
say "step 2/3: copy hooks/*.sh -> $HOOKS_DIR/"
do_or_show "mkdir -p '$HOOKS_DIR'"
for h in session-start-board.sh user-prompt-submit-board.sh pre-tool-use-board.sh session-end-board.sh; do
  src="$REPO_DIR/hooks/$h"
  dst="$HOOKS_DIR/$h"
  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    say "  $h exists, overwriting (it's our file)."
  fi
  do_or_show "cp '$src' '$dst'"
  do_or_show "chmod +x '$dst'"
done

# 3. merge settings.json
say "step 3/3: merge hook entries into $SETTINGS"
if [ ! -f "$SETTINGS" ]; then
  say "  settings.json not found, will create."
fi

BACKUP="$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
if [ -f "$SETTINGS" ] && [ "$DRY_RUN" -ne 1 ]; then
  cp "$SETTINGS" "$BACKUP"
  say "  backup: $BACKUP"
fi

PY_MERGE=$(cat <<'PYEOF'
import json, os, sys

settings_path = sys.argv[1]
dry_run = sys.argv[2] == "1"

DESIRED = {
    "SessionStart": {
        "matcher": "",
        "command": "~/.claude/hooks/session-start-board.sh",
        "timeout": 5,
    },
    "UserPromptSubmit": {
        "matcher": "",
        "command": "~/.claude/hooks/user-prompt-submit-board.sh",
        "timeout": 3,
    },
    "PreToolUse": {
        "matcher": "Edit|Write|MultiEdit|NotebookEdit",
        "command": "~/.claude/hooks/pre-tool-use-board.sh",
        "timeout": 3,
    },
    "SessionEnd": {
        "matcher": "",
        "command": "~/.claude/hooks/session-end-board.sh",
        "timeout": 3,
    },
}

if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError as e:
            print(f"  ERROR: settings.json is not valid JSON: {e}", file=sys.stderr)
            sys.exit(1)
else:
    settings = {}

settings.setdefault("hooks", {})
hooks = settings["hooks"]

added = []
skipped = []

for event, entry in DESIRED.items():
    hooks.setdefault(event, [])
    matcher_groups = hooks[event]
    target_group = None
    for g in matcher_groups:
        if g.get("matcher", "") == entry["matcher"]:
            target_group = g
            break
    if target_group is None:
        target_group = {"matcher": entry["matcher"], "hooks": []}
        matcher_groups.append(target_group)

    target_group.setdefault("hooks", [])
    already = any(
        h.get("type") == "command" and h.get("command") == entry["command"]
        for h in target_group["hooks"]
    )
    if already:
        skipped.append(f"{event}:{entry['command']}")
        continue

    target_group["hooks"].append({
        "type": "command",
        "command": entry["command"],
        "timeout": entry["timeout"],
    })
    added.append(f"{event}:{entry['command']}")

if dry_run:
    print("  (dry-run) would add:")
    for a in added or ["    (none)"]:
        print(f"    + {a}")
    if skipped:
        print("  (dry-run) already present:")
        for s in skipped:
            print(f"    - {s}")
else:
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"  added: {len(added)}, already present: {len(skipped)}")
    for a in added:
        print(f"    + {a}")
PYEOF
)

python3 -c "$PY_MERGE" "$SETTINGS" "$DRY_RUN"

say "done."
if [ "$DRY_RUN" -eq 1 ]; then
  say "(dry run, no files were changed)"
else
  say "Restart Claude Code in any project to start using sessions-board."
  say "Try: ~/.claude/bin/sessions-board --help"
fi
