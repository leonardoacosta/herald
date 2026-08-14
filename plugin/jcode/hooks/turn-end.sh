#!/usr/bin/env bash
# turn-end.sh — herald's Jcode `turn_end` observer hook adapter.
#
# Jcode spawns this detached (fire-and-forget) with the documented
# JCODE_HOOK_* env payload (see Jcode's bundled docs/HOOKS.md). This script:
#
#   1. gates on a minimum turn duration (HERALD_JCODE_MIN_TURN_MS, default
#      30000 ms) so trivial turns stay silent,
#   2. skips when there is no assistant text to summarize,
#   3. derives a short spoken summary (project dir name + ok/error),
#   4. delegates to $HERALD/bin/notify.sh — the one pipe. No parallel
#      speech implementation lives here.
#
# ALWAYS EXITS 0, bounded. A notification is decoration; Jcode's observer
# hooks are already detached, so the timeout here is belt-and-braces.
#
# Env knobs:
#   HERALD                    herald repo root (defaults to this script's repo;
#                             silent no-op when unresolvable)
#   HERALD_JCODE_MIN_TURN_MS  minimum JCODE_HOOK_DURATION_MS to notify (30000)
#   HERALD_JCODE_TIMEOUT      bound on the notify.sh delegation, seconds (15)
set -u

# Resolve the herald root. Explicit $HERALD wins; otherwise derive it from
# this script's own location (plugin/jcode/hooks/ -> repo root), because
# Jcode does not inject $HERALD into hook environments.
HERALD="${HERALD:-}"
if [ -z "$HERALD" ]; then
  HERALD="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)" || HERALD=""
fi
[ -n "$HERALD" ] || exit 0
NOTIFY="$HERALD/bin/notify.sh"
[ -x "$NOTIFY" ] || exit 0

# Only act on the event we are wired for.
[ "${JCODE_HOOK_EVENT:-turn_end}" = "turn_end" ] || exit 0

# Threshold gate: trivial turns stay silent.
MIN_MS="${HERALD_JCODE_MIN_TURN_MS:-30000}"
DUR_MS="${JCODE_HOOK_DURATION_MS:-0}"
case "$MIN_MS" in ''|*[!0-9]*) MIN_MS=30000 ;; esac
case "$DUR_MS" in ''|*[!0-9]*) DUR_MS=0 ;; esac
[ "$DUR_MS" -ge "$MIN_MS" ] || exit 0

# No assistant text -> nothing worth speaking.
TEXT="${JCODE_HOOK_LAST_ASSISTANT_TEXT:-}"
[ -n "$TEXT" ] || exit 0

# Summary: project dir name + status. Hooks run in the session cwd when
# known, but must not depend on it — prefer the payload's cwd field.
PROJECT_DIR="${JCODE_HOOK_CWD:-$PWD}"
PROJECT="$(basename "$PROJECT_DIR" 2>/dev/null || echo jcode)"
STATE="${JCODE_HOOK_STATUS:-ok}"
if [ "$STATE" = "ok" ]; then
  SUMMARY="Jcode turn done in $PROJECT"
else
  SUMMARY="Jcode turn error in $PROJECT"
fi

TIMEOUT_S="${HERALD_JCODE_TIMEOUT:-15}"
case "$TIMEOUT_S" in ''|*[!0-9]*) TIMEOUT_S=15 ;; esac

# Delegate to the one pipe. notify.sh itself always exits 0; the timeout is
# only a bound against a hung transport.
timeout "$TIMEOUT_S" "$NOTIFY" "$SUMMARY" >/dev/null 2>&1 || true
exit 0
