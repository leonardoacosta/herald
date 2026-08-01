#!/usr/bin/env bash
# Live Kokoro acceptance with isolated Herald state and no operator playback.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-voice-live.XXXXXX)"
cleanup() {
  case "$TMP" in
    /tmp/herald-voice-live.*) rm -rf -- "$TMP" ;;
  esac
}
trap cleanup EXIT INT TERM

# shellcheck disable=SC1091
source "$REPO/bin/lib.sh"
export HERALD_BIN="$TMP/herald"
export HERALD_STATE_DIR="$TMP/state"
export HERALD_PROJECTS_TOML="${HERALD_PROJECTS_TOML:-${SHEPHERD_PROJECTS_TOML:-${DOTFILES:-$HOME/dev/personal/installfest}/home/projects.toml}}"
HERALD_KOKORO_BASE_URL="$(herald_config NOTIFY_KOKORO_BASE_URL HERALD_KOKORO_BASE_URL http://127.0.0.1:8880 HERDR_KOKORO_BASE_URL)"
export HERALD_KOKORO_BASE_URL
export HERALD_NOTIFY_PLAYBACK_HOST=127.0.0.1
export HERALD_NOTIFY_PLAYBACK_TIMEOUT=1
PROJECT_CODE="${HERALD_LIVE_PROJECT_CODE:-hs}"

go build -o "$HERALD_BIN" "$REPO/cmd/herald"

catalog_json="$("$HERALD_BIN" notify catalog --json --timeout 10)"
printf '%s' "$catalog_json" | jq -e 'length > 0 and any(.[]; .id == "af_bella")' >/dev/null

"$HERALD_BIN" notify audition --voice kokoro:af_bella --timeout 30 >/dev/null
[ ! -e "$HERALD_STATE_DIR/voices.json" ]
[ ! -e "$HERALD_STATE_DIR/notify.ndjson" ]

"$HERALD_BIN" notify set --project "$PROJECT_CODE" --voice kokoro:af_bella --timeout 10 >/dev/null
[ "$(stat -c %a "$HERALD_STATE_DIR/voices.json")" = 600 ]
"$REPO/bin/notify.sh" --wait --project "$PROJECT_CODE" "Herald voice management verification completed." >/dev/null 2>&1
jq -e --arg project "$PROJECT_CODE" 'select(.project == $project and .voice == "kokoro:af_bella")' \
  "$HERALD_STATE_DIR/notify.ndjson" >/dev/null

"$HERALD_BIN" notify reset --project "$PROJECT_CODE" >/dev/null
effective_json="$("$HERALD_BIN" notify voices --json)"
printf '%s' "$effective_json" | jq -e --arg project "$PROJECT_CODE" \
  'any(.[]; .project == $project and .stored == "" and .effective == "kokoro:af_heart" and .source == "builtin")' \
  >/dev/null

before_lines="$(wc -l < "$HERALD_STATE_DIR/notify.ndjson")"
"$REPO/bin/notify.sh" --wait --project "$PROJECT_CODE" "Herald fallback voice verification completed." >/dev/null 2>&1
after_lines="$(wc -l < "$HERALD_STATE_DIR/notify.ndjson")"
[ "$after_lines" -eq $((before_lines + 1)) ]
tail -n 1 "$HERALD_STATE_DIR/notify.ndjson" | jq -e --arg project "$PROJECT_CODE" \
  'select(.project == $project and .voice == "kokoro:af_heart")' >/dev/null

echo "live voice acceptance: catalog, isolated audition, override, notify resolution, reset, fallback passed"
