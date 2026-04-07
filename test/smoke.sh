#!/bin/bash
# claude-sessions-board: end-to-end smoke test
# Exercises the CLI without touching the user's real coordination state by
# pointing HOME at a temp directory. Run from the repo root: ./test/smoke.sh

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOARD="$REPO_DIR/bin/sessions-board"

if [ ! -x "$BOARD" ]; then
  echo "FAIL: $BOARD not executable" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP"
PROJECT="$TMP/project"
mkdir -p "$PROJECT"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; exit 1; }

run_step() { echo; echo "[$1]"; }

run_step "register sessA"
"$BOARD" --cwd "$PROJECT" register --session-id sessA --branch main >/dev/null
[ -f "$TMP/.claude/coordination/projects"/*/sessions/sessA.json ] && pass "sessA file exists" || fail "sessA file missing"

run_step "summary"
"$BOARD" --cwd "$PROJECT" summary "implementing auth" --session-id sessA >/dev/null
"$BOARD" --cwd "$PROJECT" list --session-id sessA | grep -q "implementing auth" && pass "summary visible in list" || fail "summary missing"

run_step "register sessB and see sessA"
"$BOARD" --cwd "$PROJECT" register --session-id sessB --branch feat/x >/dev/null
LIST=$("$BOARD" --cwd "$PROJECT" list --session-id sessB)
echo "$LIST" | grep -q "sessA" && pass "sessB sees sessA" || fail "sessB cannot see sessA"
echo "$LIST" | grep -q "sessB" && pass "sessB sees itself" || fail "sessB missing"

run_step "lock + check-lock self"
"$BOARD" --cwd "$PROJECT" lock "$PROJECT/auth.ts" --session-id sessA >/dev/null
"$BOARD" --cwd "$PROJECT" check-lock "$PROJECT/auth.ts" --session-id sessA && pass "self check passes"

run_step "check-lock from intruder must deny"
set +e
REASON=$("$BOARD" --cwd "$PROJECT" check-lock "$PROJECT/auth.ts" --session-id sessB 2>&1 >/dev/null)
EXIT=$?
set -e
[ $EXIT -eq 2 ] && pass "intruder denied with exit 2" || fail "intruder not denied (exit=$EXIT)"
echo "$REASON" | grep -q "locked by another Claude Code session" && pass "reason mentions lock" || fail "reason missing"
echo "$REASON" | grep -q "sessions-board send sessA" && pass "reason includes coordination hint" || fail "hint missing"

run_step "send and receive message"
"$BOARD" --cwd "$PROJECT" send sessA "please release auth.ts" --session-id sessB >/dev/null
INBOX=$("$BOARD" --cwd "$PROJECT" inbox --session-id sessA)
echo "$INBOX" | grep -q "please release auth.ts" && pass "sessA receives message" || fail "message not received"

run_step "second inbox call shows empty (rename to processed worked)"
SECOND=$("$BOARD" --cwd "$PROJECT" inbox --session-id sessA)
echo "$SECOND" | grep -q "no new messages" && pass "messages moved to processed" || fail "messages still pending: $SECOND"

run_step "unlock"
"$BOARD" --cwd "$PROJECT" unlock "$PROJECT/auth.ts" --session-id sessA >/dev/null
"$BOARD" --cwd "$PROJECT" check-lock "$PROJECT/auth.ts" --session-id sessB && pass "intruder allowed after unlock"

run_step "unregister cleanup"
"$BOARD" --cwd "$PROJECT" unregister --session-id sessA >/dev/null
"$BOARD" --cwd "$PROJECT" unregister --session-id sessB >/dev/null
LEFT=$("$BOARD" --cwd "$PROJECT" list 2>/dev/null || true)
echo "$LEFT" | grep -q "no active sessions" && pass "no sessions left" || fail "sessions not cleaned: $LEFT"

run_step "different cwd = different board"
"$BOARD" --cwd "$PROJECT" register --session-id isolated_a --branch main >/dev/null
mkdir -p "$TMP/other"
"$BOARD" --cwd "$TMP/other" register --session-id isolated_b --branch main >/dev/null
"$BOARD" --cwd "$PROJECT" list --session-id isolated_a | grep -qv "isolated_b" && pass "boards isolated by cwd"
"$BOARD" --cwd "$PROJECT" unregister --session-id isolated_a >/dev/null
"$BOARD" --cwd "$TMP/other" unregister --session-id isolated_b >/dev/null

echo
echo "All smoke tests passed."
