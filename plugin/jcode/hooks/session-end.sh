#!/usr/bin/env bash
# session-end.sh — herald's Jcode `session_end` observer hook adapter.
#
# DEFAULT OFF. Jcode sessions open and close far more often than cc
# sessions, so this only speaks when the operator opts in with
# HERALD_JCODE_SESSION_END=1. Same fail-soft shape as turn-end.sh:
# always exits 0, bounded, delegates to $HERALD/bin/notify.sh only.
set -u

[ "${HERALD_JCODE_SESSION_END:-0}" = "1" ] || exit 0

HERALD="${HERALD:-}"
if [ -z "$HERALD" ]; then
  HERALD="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)" || HERALD=""
fi
[ -n "$HERALD" ] || exit 0
NOTIFY="$HERALD/bin/notify.sh"
[ -x "$NOTIFY" ] || exit 0

[ "${JCODE_HOOK_EVENT:-session_end}" = "session_end" ] || exit 0

PROJECT_DIR="${JCODE_HOOK_CWD:-$PWD}"
PROJECT="$(basename "$PROJECT_DIR" 2>/dev/null || echo jcode)"
SUMMARY="Jcode session closed in $PROJECT"

TIMEOUT_S="${HERALD_JCODE_TIMEOUT:-15}"
case "$TIMEOUT_S" in ''|*[!0-9]*) TIMEOUT_S=15 ;; esac

timeout "$TIMEOUT_S" "$NOTIFY" "$SUMMARY" >/dev/null 2>&1 || true
exit 0
