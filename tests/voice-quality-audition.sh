#!/usr/bin/env bash
# Audible A/B sequence for the voice-quality user decision.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-voice-quality.XXXXXX)"
cleanup() {
  case "$TMP" in
    /tmp/herald-voice-quality.*) rm -rf -- "$TMP" ;;
  esac
}
trap cleanup EXIT INT TERM

# shellcheck disable=SC1091
source "$REPO/bin/lib.sh"
export HERALD_BIN="$TMP/herald"
export HERALD_STATE_DIR="$TMP/state"
HERALD_KOKORO_BASE_URL="$(herald_config NOTIFY_KOKORO_BASE_URL HERALD_KOKORO_BASE_URL http://127.0.0.1:8880 HERDR_KOKORO_BASE_URL)"
export HERALD_KOKORO_BASE_URL
mkdir -p "$HERALD_STATE_DIR"
go build -o "$HERALD_BIN" "$REPO/cmd/herald"

SAMPLE="Herald finished the requested work, and the result is ready for your next decision."

run_candidate() {
  local number="$1" label="$2" voice="$3" speed="$4"
  jq -n --arg voice "$voice" --argjson speed "$speed" \
    '{default:{voice:$voice,speed:$speed},projects:{}}' > "$HERALD_STATE_DIR/voices.json"
  chmod 600 "$HERALD_STATE_DIR/voices.json"
  "$REPO/bin/notify.sh" --wait "$SAMPLE" >/dev/null 2>&1
  tail -n 1 "$HERALD_STATE_DIR/notify.ndjson" | jq -e \
    --arg voice "$voice" --argjson speed "$speed" \
    'select(.outcome == "delivered" and .voice == $voice and .speed == $speed)' >/dev/null
  printf '%s\t%s\t%s\t%s\n' "$number" "$label" "$voice" "$speed"
}

run_candidate 1 "Heart baseline" "kokoro:af_heart" 1.0
run_candidate 2 "Bella baseline" "kokoro:af_bella" 1.0
run_candidate 3 "Nicole slower" "kokoro:af_nicole" 0.9
run_candidate 4 "Heart and Bella blend" "kokoro:af_heart+af_bella(2)" 0.95
run_candidate 5 "Heart and Nicole blend" "kokoro:af_heart+af_nicole(2)" 0.95

echo "voice-quality audition: five delivered samples passed"
