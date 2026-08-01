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

set +e
"$REPO/bin/notify.sh" --project smoke "fail-soft smoke" >/dev/null 2>&1
rc=$?
set -e

[ "$rc" -eq 0 ] || { echo "notify pipe returned $rc, want 0" >&2; exit 1; }
[ -f "$HERALD_STATE_DIR/notify.ndjson" ] || { echo "history was not created" >&2; exit 1; }
[ "$(wc -l < "$HERALD_STATE_DIR/notify.ndjson")" -eq 1 ] || { echo "history does not contain exactly one attempt" >&2; exit 1; }
jq -e 'select(.project == "smoke" and .outcome == "synth_failed")' \
  "$HERALD_STATE_DIR/notify.ndjson" >/dev/null

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
