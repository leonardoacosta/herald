#!/usr/bin/env bash
# Exercise the public pipe against a deliberately unreachable synthesizer.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-smoke.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

go build -o "$TMP/herald" "$REPO/cmd/herald"

export HERALD_BIN="$TMP/herald"
export HERALD_CONFIG_DIR="$TMP/config"
export HERALD_STATE_DIR="$TMP/state"
export HERALD_KOKORO_BASE_URL="http://127.0.0.1:1"
export HERALD_NOTIFY_SYNTH_TIMEOUT="1"
mkdir -p "$HERALD_STATE_DIR"
printf '%s\n' '{"default":{"voice":"kokoro:af_heart","speed":0.9},"projects":{}}' \
  > "$HERALD_STATE_DIR/voices.json"

printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$HERALD_STATE_DIR/mute"
"$REPO/bin/notify.sh" --project smoke "muted smoke" >/dev/null 2>&1
[ "$(wc -l < "$HERALD_STATE_DIR/notify.ndjson")" -eq 1 ] || { echo "muted attempt was not recorded exactly once" >&2; exit 1; }
jq -e 'select(.project == "smoke" and .outcome == "muted" and .voice == "kokoro:af_heart" and .speed == 0.9)' \
  "$HERALD_STATE_DIR/notify.ndjson" >/dev/null

printf '%s\n' "$(( $(date +%s) - 1 ))" > "$HERALD_STATE_DIR/mute"

set +e
"$REPO/bin/notify.sh" --project smoke "fail-soft smoke" >/dev/null 2>&1
rc=$?
set -e

[ "$rc" -eq 0 ] || { echo "notify pipe returned $rc, want 0" >&2; exit 1; }
[ -f "$HERALD_STATE_DIR/notify.ndjson" ] || { echo "history was not created" >&2; exit 1; }
[ ! -e "$HERALD_STATE_DIR/mute" ] || { echo "expired mute file was not removed" >&2; exit 1; }
[ "$(wc -l < "$HERALD_STATE_DIR/notify.ndjson")" -eq 2 ] || { echo "history does not contain exactly two attempts" >&2; exit 1; }
tail -n 1 "$HERALD_STATE_DIR/notify.ndjson" | jq -e \
  'select(.project == "smoke" and .outcome == "synth_failed" and .speed == 0.9)' >/dev/null

mkdir -p "$TMP/repo/bin"
cp "$REPO/bin/notify.sh" "$REPO/bin/lib.sh" "$TMP/repo/bin/"
export HOME="$TMP/home"
export HERALD_BIN="$TMP/missing-herald"
export HERALD_CONFIG_DIR="$TMP/missing-config"
export HERALD_STATE_DIR="$TMP/missing-state"
PATH="/usr/bin:/bin" "$TMP/repo/bin/notify.sh" --project smoke "missing binary" >/dev/null 2>&1
[ "$(wc -l < "$HERALD_STATE_DIR/notify.ndjson")" -eq 1 ] || { echo "missing-binary attempt was not recorded exactly once" >&2; exit 1; }
jq -e 'select(.project == "smoke" and .outcome == "synth_failed" and .reason == "herald binary unavailable")' \
  "$HERALD_STATE_DIR/notify.ndjson" >/dev/null

echo "notify smoke: synthesis and missing-binary failures recorded fail-soft"
