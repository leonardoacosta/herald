#!/usr/bin/env bash
# deep-briefings task 1.2 — say_brief's fail-soft contract on a long text.
#
# Hermetic by construction: the state dir is a temp dir and Kokoro is pointed at
# a dead port, so synthesis fails before the pipe ever reaches for ssh. The
# Kokoro-up half of the contract is a live check against the deployed service,
# not a committed test — it would ssh to the operator's playback host.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$REPO/plugin"
TMP="$(mktemp -d -t herald-brief.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

[ -x "$REPO/bin/herald" ] || go build -C "$REPO" -o bin/herald ./cmd/herald

BRIEF="$(printf 'briefing %.0s' $(seq 150))"
[ "$(printf '%s' "$BRIEF" | wc -w)" -eq 150 ]

START="$(date +%s)"
HERALD="$REPO" \
HERALD_STATE_DIR="$TMP/state" \
HERALD_KOKORO_BASE_URL="http://127.0.0.1:1" \
  bash -c 'source "$1"; say_brief -p hs "$2"; echo "rc=$?"' _ "$PLUGIN/lib/notify.sh" "$BRIEF" \
  > "$TMP/out" 2>"$TMP/err"
ELAPSED=$(( $(date +%s) - START ))

rg -q '^rc=0$' "$TMP/out" || { echo "say_brief did not exit 0 on a dead Kokoro" >&2; exit 1; }
[ "$ELAPSED" -lt 60 ] || { echo "say_brief took ${ELAPSED}s, past its 60s bound" >&2; exit 1; }

HISTORY="$TMP/state/notify.ndjson"
[ -f "$HISTORY" ] || { echo "a failed briefing wrote no history record" >&2; exit 1; }
[ "$(wc -l < "$HISTORY")" -eq 1 ] || { echo "one briefing wrote $(wc -l < "$HISTORY") records" >&2; exit 1; }

jq -e '.outcome == "synth_failed" and (.reason | length > 0) and .project == "hs"' \
  "$HISTORY" >/dev/null || { echo "record is not a reasoned synth_failed: $(cat "$HISTORY")" >&2; exit 1; }

# Task 1.3's cap, observed end to end rather than only in the Go unit test: the
# 150-word text reaches the store and comes back out shortened.
jq -e '(.text | length) == 300 and (.text | endswith("…"))' "$HISTORY" >/dev/null || {
  echo "recorded text was not capped: $(jq -r '.text | length' "$HISTORY") chars" >&2
  exit 1
}

echo "notify brief: dead Kokoro exits 0 in ${ELAPSED}s with a capped synth_failed record"
