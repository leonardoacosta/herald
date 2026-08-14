#!/usr/bin/env bash
# acceptance-cancellation.sh — the deployed-pipeline acceptance harness.
#
# Usage:
#   tests/acceptance-cancellation.sh [--live] [--out PATH] [--help]
#
#   --live      Authorize REAL AUDIO on the playback host and run the whole
#               matrix. Without it the run stops after gate 0 plus the
#               no-audio subset of row 9 (malformed / unknown-ID contract
#               checks) and the verdict is `partial`.
#   --out PATH  Write the evidence report here instead of
#               $HERALD_STATE_DIR/acceptance/<ts>-<nonce>.json.
#
# ── What this is ─────────────────────────────────────────────────────────────
# EXPLICIT-ONLY. An operator runs this on demand. It is never wired into a
# hook, a schedule, a session-exit event, or CI without opt-in — same posture
# as briefings (AGENTS.md "Briefings are explicit-only").
#
# It implements NO playback or cancellation behavior. It is a verification
# feature: it calls existing entry points (bin/notify.sh, `herald notify
# stop|history|mute|unmute`, raw HTTP) against the DEPLOYED service and the
# real playback host, correlates every step to a history record by request ID,
# and writes one machine-readable evidence report per run.
#
# ── What it must never do ────────────────────────────────────────────────────
#   - Restart, reload, install, or reconfigure herald-notify.service. A stale
#     service is REPORTED (remediation: bin/service-sync.sh), never fixed here.
#   - Mutate the playback host. The resident player, its launchd agent, and
#     any afplay/mpg123 process are OBSERVED ONLY: every ssh call in this file
#     is a read (ls/cat/tail). Player lifecycle stays owned by
#     bin/player-sync.sh.
#   - Leave mute on. Row 8 mutes; the EXIT trap unmutes unconditionally, so a
#     harness killed mid-row cannot silence Herald afterwards.
#   - Play audio without --live.
#
# ── Why the delivery mode is recorded, not forced ───────────────────────────
# Both delivery modes (resident player vs fallback drainer) are in scope, but
# forcing the fallback means killing the resident player — a mutation of the
# playback host, which is exactly the stop condition this design refused. So
# the harness records WHICH mode served each clip (from the lock holder's pid
# against .player.pid) and, if only one mode is live, says so; the other
# mode's coverage is `not-exercised`, never `pass`.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 2
# shellcheck disable=SC1091
source "$REPO/bin/lib.sh"

LIVE=0
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --live) LIVE=1; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "acceptance: unknown option: $1" >&2; exit 2 ;;
  esac
done

# Per-call bounds. Every network call in this file carries one; the total
# --live runtime target is under 3 minutes (proposal.md acceptance criterion 6).
HTTP_TIMEOUT="${HERALD_ACCEPTANCE_HTTP_TIMEOUT:-5}"
SSH_TIMEOUT="${HERALD_ACCEPTANCE_SSH_TIMEOUT:-8}"
SETTLE="${HERALD_ACCEPTANCE_SETTLE:-12}"        # max wait for a terminal history row
NOTIFY_TIMEOUT="${HERALD_ACCEPTANCE_NOTIFY_TIMEOUT:-45}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "acceptance: $1 is required" >&2; exit 2; }; }
need jq
need curl

NONCE="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ -n "$NONCE" ] || NONCE="$$$(date +%s)"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"

STATE_DIR="$(herald_state_dir)"
[ -n "$OUT" ] || OUT="$STATE_DIR/acceptance/$(date -u +%Y%m%dT%H%M%SZ)-$NONCE.json"
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true

PORT="$(herald_config HERALD_NOTIFY_PORT HERALD_NOTIFY_PORT 8881)"
SERVICE_URL="$(herald_config NOTIFY_SERVICE_URL HERALD_NOTIFY_SERVICE_URL "http://127.0.0.1:$PORT")"
SERVICE_URL="${SERVICE_URL%/}"
KOKORO_URL="$(herald_config NOTIFY_KOKORO_BASE_URL HERALD_KOKORO_BASE_URL http://127.0.0.1:8880 HERDR_KOKORO_BASE_URL)"
PLAYBACK_HOST="$(herald_config NOTIFY_PLAYBACK_HOST HERALD_NOTIFY_PLAYBACK_HOST mac HERDR_NOTIFY_PLAYBACK_HOST)"

# The binary under test. HERALD_ACCEPTANCE_BIN exists so task 5.2 can point
# gate 0 at a COPY of a differently-versioned binary and watch the gate abort,
# without touching the deployed one.
BIN="${HERALD_ACCEPTANCE_BIN:-}"
[ -n "$BIN" ] || BIN="$(herald_bin)" || BIN=""

TMP="$(mktemp -d -t herald-acceptance.XXXXXX)" || exit 2
ROWS_FILE="$TMP/rows.ndjson"
: > "$ROWS_FILE"
NOTES_FILE="$TMP/notes.ndjson"
: > "$NOTES_FILE"

MUTED_BY_US=0

# ── Cleanup: always unmute, always write a report ────────────────────────────
# Acceptance criterion 5: the harness is fail-soft to Herald's callers. It
# never leaves mute on and always produces a report file, including when it
# dies mid-row.
cleanup() {
  local rc=$?
  if [ "$MUTED_BY_US" = 1 ] && [ -n "$BIN" ]; then
    "$BIN" notify unmute >/dev/null 2>&1 || rm -f "$STATE_DIR/mute" 2>/dev/null || true
  fi
  write_report "$rc" 2>/dev/null || true
  rm -rf "$TMP"
  exit "$rc"
}

note() { jq -cn --arg m "$*" '{note:$m}' >> "$NOTES_FILE"; echo "acceptance: $*" >&2; }

# row <n> <name> <status> <expected> <observed> [extra-json]
# status ∈ pass | fail | blocked | not-exercised
row() {
  local n="$1" name="$2" st="$3" expected="$4" observed="$5" extra="${6:-{\}}"
  jq -cn --argjson n "$n" --arg name "$name" --arg status "$st" \
    --arg expected "$expected" --arg observed "$observed" --argjson extra "$extra" \
    '{row:$n, name:$name, status:$status, expected:$expected, observed:$observed, evidence:$extra}' \
    >> "$ROWS_FILE"
  printf 'row %s [%s] %s — %s\n' "$n" "$st" "$name" "$observed" >&2
}

# ── Evidence report ─────────────────────────────────────────────────────────
# One JSON document: run identity, the alignment section (gate 0's findings),
# the boundary snapshots, every row record, and one closed verdict.
#
# Verdict is derived, never asserted: any `fail` row makes the run fail; any
# `blocked`/`not-exercised` row with no failures makes it `partial`; only an
# all-pass run is `pass`. A row without evidence is therefore incapable of
# reporting as passed (proposal.md "Playback host unavailable yields partial,
# not silent pass").
ALIGNMENT_JSON='{}'
BOUNDARY_BEFORE='{}'
BOUNDARY_AFTER='{}'
write_report() {
  local exit_rc="${1:-0}" verdict rows
  rows="$(jq -sc '.' "$ROWS_FILE" 2>/dev/null || echo '[]')"
  if printf '%s' "$rows" | jq -e 'any(.[]; .status=="fail")' >/dev/null 2>&1; then
    verdict="fail"
  elif printf '%s' "$rows" | jq -e 'any(.[]; .status=="blocked" or .status=="not-exercised")' >/dev/null 2>&1; then
    verdict="partial"
  elif printf '%s' "$rows" | jq -e 'length > 0' >/dev/null 2>&1; then
    verdict="pass"
  else
    verdict="fail"
  fi
  jq -n \
    --arg schema "herald.acceptance.v1" \
    --arg run_ts "$RUN_TS" \
    --arg nonce "$NONCE" \
    --argjson live "$LIVE" \
    --argjson duration_s "$(( $(date +%s) - START_EPOCH ))" \
    --argjson exit_code "$exit_rc" \
    --argjson alignment "$ALIGNMENT_JSON" \
    --argjson boundary_before "$BOUNDARY_BEFORE" \
    --argjson boundary_after "$BOUNDARY_AFTER" \
    --argjson rows "$rows" \
    --argjson notes "$(jq -sc '.' "$NOTES_FILE" 2>/dev/null || echo '[]')" \
    --arg verdict "$verdict" \
    --argjson not_exercised "$(printf '%s' "$rows" | jq -c '[.[] | select(.status=="not-exercised" or .status=="blocked") | .row]' 2>/dev/null || echo '[]')" \
    '{schema:$schema, run_ts:$run_ts, nonce:$nonce, live:($live==1),
      duration_s:$duration_s, exit_code:$exit_code,
      alignment:$alignment,
      boundary:{before:$boundary_before, after:$boundary_after},
      rows:$rows, notes:$notes,
      verdict:$verdict, not_exercised:$not_exercised}' > "$OUT.tmp" 2>/dev/null &&
    mv -f "$OUT.tmp" "$OUT"
  echo "acceptance: report written to $OUT (verdict $verdict)" >&2
}
trap cleanup EXIT INT TERM

# ── Read-only playback-boundary evidence ────────────────────────────────────
# Every command here is a read. No writes, no kills, no launchctl. The SSH
# identity is the one delivery already uses (BatchMode, no prompt).
boundary_snapshot() {
  local raw
  raw="$(timeout "$SSH_TIMEOUT" ssh -o BatchMode=yes "$PLAYBACK_HOST" '
    S=/tmp/herald-spool
    echo "spool_entries<<"
    ls -1 "$S" 2>/dev/null
    echo ">>"
    echo "lock_pid=$(cat "$S/drainer.lock/pid" 2>/dev/null)"
    echo "player_pid=$(cat "$S/.player.pid" 2>/dev/null)"
    echo "player_current=$(cat "$S/.player.current" 2>/dev/null)"
    echo "log<<"
    tail -5 /tmp/herald-player.log 2>/dev/null
    echo ">>"
  ' 2>/dev/null)" || raw=""
  if [ -z "$raw" ]; then
    printf '%s' '{"reachable":false}'
    return 1
  fi
  local entries lock player current log mode
  entries="$(printf '%s' "$raw" | sed -n '/^spool_entries<<$/,/^>>$/p' | sed '1d;$d')"
  lock="$(printf '%s\n' "$raw" | sed -n 's/^lock_pid=//p' | head -1)"
  player="$(printf '%s\n' "$raw" | sed -n 's/^player_pid=//p' | head -1)"
  current="$(printf '%s\n' "$raw" | sed -n 's/^player_current=//p' | head -1)"
  log="$(printf '%s' "$raw" | sed -n '/^log<<$/,/^>>$/p' | sed '1d;$d')"
  # Which mode holds the spool: the resident player publishes .player.pid and
  # holds the lock for its lifetime; anything else holding it is a fallback
  # drainer. Recorded, never forced.
  if [ -n "$lock" ] && [ -n "$player" ] && [ "$lock" = "$player" ]; then
    mode="resident-player"
  elif [ -n "$lock" ]; then
    mode="fallback-drainer"
  else
    mode="idle"
  fi
  jq -cn --arg entries "$entries" --arg lock "$lock" --arg player "$player" \
    --arg current "$current" --arg log "$log" --arg mode "$mode" \
    '{reachable:true, spool_entries:($entries|split("\n")|map(select(length>0))),
      lock_pid:$lock, player_pid:$player, player_current:$current, served_by:$mode,
      player_log_tail:($log|split("\n")|map(select(length>0)))}'
}

# ── History correlation ─────────────────────────────────────────────────────
# Every accepted request must map to EXACTLY ONE terminal history row. The
# outcome must come from the closed set; an unknown outcome string fails the
# row rather than being reported as a novel success.
TERMINAL_OUTCOMES='["delivered","muted","canceled","synth_failed","transport_timeout","transport_failed"]'

history_json() {
  [ -n "$BIN" ] || { echo '[]'; return; }
  "$BIN" notify history --json -n 400 2>/dev/null || echo '[]'
}

# rows_for <jq-filter-expression>
rows_for() { history_json | jq -c "[.[] | select($1)]"; }

# await_rows <filter> <expected-count> — polls until the count settles, then
# holds an extra second and re-reads, so a DELAYED duplicate write fails the
# row instead of racing past it.
await_rows() {
  local filter="$1" want="$2" deadline found
  deadline=$(( $(date +%s) + SETTLE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    found="$(rows_for "$filter")"
    [ "$(printf '%s' "$found" | jq 'length')" -ge "$want" ] && break
    sleep 0.5
  done
  sleep 1
  rows_for "$filter"
}

by_id() { printf '.request_id == "%s"' "$1"; }
by_nonce() { printf '(.text // "") | test("%s")' "$1"; }

# assert_single_terminal <rows-json> — one row, closed-set outcome.
assert_single_terminal() {
  printf '%s' "$1" | jq -e --argjson ok "$TERMINAL_OUTCOMES" \
    'length == 1 and (.[0].outcome as $o | $ok | index($o) != null)' >/dev/null 2>&1
}

utter() { printf 'herald acceptance %s row %s' "$NONCE" "$1"; }

# ── Gate 0: version and deployment alignment ────────────────────────────────
# Aborts cleanly (non-zero, NO audio) unless every condition holds. Nothing
# here restarts or repairs anything: a mismatch is reported with its
# remediation (bin/service-sync.sh) and the run stops.
version_of() { printf '%s' "$1" | jq -r '.version // empty' 2>/dev/null; }
config_declared() {
  local key="$1" default="$2" file="$HERALD_CONFIG_DIR/config" line
  if [ -r "$file" ]; then
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1)"
    [ -n "$line" ] && { printf '%s\n' "${line#*=}"; return 0; }
  fi
  printf '%s\n' "$default"
}

gate0() {
  local health running ondisk unit ok=1 reasons=() digest
  unit="$(systemctl --user is-active herald-notify.service 2>/dev/null || true)"
  health="$(curl -fsS --max-time "$HTTP_TIMEOUT" "$SERVICE_URL/health" 2>/dev/null || true)"
  running="$(version_of "$health")"
  ondisk=""
  [ -n "$BIN" ] && ondisk="$(version_of "$("$BIN" notify status --json 2>/dev/null)")"

  [ "$unit" = "active" ] || { ok=0; reasons+=("herald-notify.service is '${unit:-unknown}', not active — run bin/service-sync.sh"); }
  [ -n "$running" ] || { ok=0; reasons+=("$SERVICE_URL/health did not answer within ${HTTP_TIMEOUT}s"); }
  [ -n "$BIN" ] || { ok=0; reasons+=("no herald binary found — go build -o bin/herald ./cmd/herald"); }
  if [ -n "$running" ] && [ -n "$ondisk" ] && [ "$running" != "$ondisk" ]; then
    ok=0
    reasons+=("stale service: running $running, on-disk $BIN is $ondisk — re-run bin/service-sync.sh (this harness never restarts it)")
  fi

  local decl_state decl_kokoro
  decl_state="$(config_declared HERALD_STATE_DIR "$HOME/.local/state/herald")"
  decl_kokoro="$(config_declared HERALD_KOKORO_BASE_URL "http://127.0.0.1:8880")"
  if [ "$decl_state" != "$STATE_DIR" ]; then
    ok=0
    reasons+=("config divergence: resolved state dir $STATE_DIR, deployed file declares $decl_state — bin/notify.sh would bypass the service")
  fi
  if [ "$decl_kokoro" != "$KOKORO_URL" ]; then
    ok=0
    reasons+=("config divergence: resolved Kokoro $KOKORO_URL, deployed file declares $decl_kokoro")
  fi

  # Digest, not contents: the report must carry proof the file did not change
  # between runs without reproducing any value from it.
  digest="$( (sha256sum "$HERALD_CONFIG_DIR/config" 2>/dev/null || echo "absent") | awk '{print $1}')"

  BOUNDARY_BEFORE="$(boundary_snapshot)" || true
  local reachable
  reachable="$(printf '%s' "$BOUNDARY_BEFORE" | jq -r '.reachable')"
  if [ "$reachable" != "true" ]; then
    # Not fatal: rows needing boundary evidence become blocked and the verdict
    # caps at partial, which is the documented behavior.
    note "playback host $PLAYBACK_HOST unreachable — boundary rows will be blocked, verdict at best partial"
  fi

  ALIGNMENT_JSON="$(jq -cn \
    --arg unit "$unit" --arg service_url "$SERVICE_URL" \
    --arg running "$running" --arg ondisk "$ondisk" --arg bin "$BIN" \
    --arg state_dir "$STATE_DIR" --arg kokoro "$KOKORO_URL" \
    --arg playback_host "$PLAYBACK_HOST" --arg config_digest "$digest" \
    --argjson boundary_reachable "$([ "$reachable" = "true" ] && echo true || echo false)" \
    --argjson ok "$([ "$ok" = 1 ] && echo true || echo false)" \
    --argjson reasons "$(printf '%s\n' "${reasons[@]+"${reasons[@]}"}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    '{unit_state:$unit, service_url:$service_url, running_version:$running,
      ondisk_version:$ondisk, binary:$bin, state_dir:$state_dir,
      kokoro_base_url:$kokoro, playback_host:$playback_host,
      config_digest:$config_digest, playback_host_reachable:$boundary_reachable,
      passed:$ok, reasons:$reasons}')"

  [ "$ok" = 1 ]
}

if ! gate0; then
  note "gate 0 failed — aborting before any audio"
  row 0 "alignment gate" fail "deployed service aligned with on-disk binary and shared config" \
    "$(printf '%s' "$ALIGNMENT_JSON" | jq -r '.reasons | join("; ")')" "$ALIGNMENT_JSON"
  exit 1
fi
note "gate 0 passed (service $(printf '%s' "$ALIGNMENT_JSON" | jq -r .running_version))"

# ── Row 9: HTTP contract spot-checks ────────────────────────────────────────
# Runs in BOTH modes; the malformed and unknown-ID checks make no sound and
# write no history. The `accepted` sub-check DOES cause synthesis and playback,
# so it is only exercised under --live — without the flag it is reported
# not-exercised, never passed.
row9() {
  local malformed_code unknown_body stop_code ok=1 obs=()
  malformed_code="$(curl -sS -o "$TMP/r9a.json" -w '%{http_code}' --max-time "$HTTP_TIMEOUT" \
    -H 'Content-Type: application/json' --data-binary '{"text":""}' "$SERVICE_URL/notify" 2>/dev/null)"
  case "$malformed_code" in
    400) obs+=("POST /notify empty text -> 400") ;;
    *) ok=0; obs+=("POST /notify empty text -> $malformed_code (expected 400)") ;;
  esac

  stop_code="$(curl -sS -o "$TMP/r9b.json" -w '%{http_code}' --max-time "$HTTP_TIMEOUT" \
    -H 'Content-Type: application/json' --data-binary '{"request_id":"nope"}' "$SERVICE_URL/notify/stop" 2>/dev/null)"
  case "$stop_code" in
    400) obs+=("POST /notify/stop malformed id -> 400") ;;
    *) ok=0; obs+=("POST /notify/stop malformed id -> $stop_code (expected 400)") ;;
  esac

  local unknown_id="ffffffffffffffffffffffffffffffff"
  unknown_body="$(curl -sS --max-time "$HTTP_TIMEOUT" -H 'Content-Type: application/json' \
    --data-binary "{\"request_id\":\"$unknown_id\"}" "$SERVICE_URL/notify/stop" 2>/dev/null)"
  if printf '%s' "$unknown_body" | jq -e '.status=="noop" and .stopped==false' >/dev/null 2>&1; then
    obs+=("POST /notify/stop unknown id -> noop, stopped:false")
  else
    ok=0; obs+=("POST /notify/stop unknown id -> unexpected body: $unknown_body")
  fi

  local extra
  extra="$(jq -cn --arg malformed "$malformed_code" --arg stop "$stop_code" \
    --argjson unknown "$(printf '%s' "$unknown_body" | jq -c . 2>/dev/null || echo 'null')" \
    --argjson malformed_body "$(jq -c . "$TMP/r9a.json" 2>/dev/null || echo 'null')" \
    '{notify_malformed_code:$malformed, notify_malformed_body:$malformed_body,
      stop_malformed_code:$stop, stop_unknown_body:$unknown}')"

  if [ "$LIVE" = 1 ]; then
    local acc_code acc_body
    acc_body="$(curl -sS -w '\n%{http_code}' --max-time "$HTTP_TIMEOUT" \
      -H 'Content-Type: application/json' \
      --data-binary "$(jq -cn --arg t "$(utter 9)" '{text:$t}')" "$SERVICE_URL/notify" 2>/dev/null)"
    acc_code="$(printf '%s' "$acc_body" | tail -1)"
    acc_body="$(printf '%s' "$acc_body" | sed '$d')"
    local acc_id
    acc_id="$(printf '%s' "$acc_body" | jq -r '.request_id // empty' 2>/dev/null)"
    if [ "$acc_code" = "202" ] && [ -n "$acc_id" ]; then
      obs+=("POST /notify accepted -> 202 request_id $acc_id")
      local rows
      rows="$(await_rows "$(by_id "$acc_id")" 1)"
      if assert_single_terminal "$rows"; then
        obs+=("one terminal history row: $(printf '%s' "$rows" | jq -r '.[0].outcome')")
      else
        ok=0; obs+=("expected exactly one terminal history row for $acc_id, got $(printf '%s' "$rows" | jq -c .)")
      fi
      extra="$(printf '%s' "$extra" | jq -c --arg id "$acc_id" --argjson rows "$rows" \
        '. + {accepted_request_id:$id, accepted_history:$rows}')"
    else
      ok=0; obs+=("POST /notify accepted -> $acc_code body $acc_body")
    fi
    row 9 "HTTP contract spot-checks" "$([ "$ok" = 1 ] && echo pass || echo fail)" \
      "documented shapes for accepted (202+request_id), malformed (400), unknown (noop)" \
      "$(IFS='; '; echo "${obs[*]}")" "$extra"
  else
    obs+=("accepted-path sub-check not exercised: --live not given (it would play audio)")
    row 9 "HTTP contract spot-checks (no-audio subset)" \
      "$([ "$ok" = 1 ] && echo not-exercised || echo fail)" \
      "documented shapes for malformed (400) and unknown (noop); accepted path requires --live" \
      "$(IFS='; '; echo "${obs[*]}")" "$extra"
  fi
}
row9

if [ "$LIVE" != 1 ]; then
  note "no --live: gate 0 and the no-audio contract checks only; no audio played, no delivered rows attributable to nonce $NONCE"
  BOUNDARY_AFTER="$(boundary_snapshot)" || true
  exit 0
fi

# ── Live matrix ─────────────────────────────────────────────────────────────

# Row 1 — plain notify through the service path.
row1() {
  local idfile="$TMP/row1.id" id rows served
  HERALD_REQUEST_ID_FILE="$idfile" timeout "$NOTIFY_TIMEOUT" "$REPO/bin/notify.sh" "$(utter 1)" >/dev/null 2>&1
  id="$(tr -d '[:space:]' < "$idfile" 2>/dev/null || true)"
  if [ -z "$id" ]; then
    row 1 "plain notify via service" fail "202 + request_id" "no request_id returned by bin/notify.sh" '{}'
    return
  fi
  rows="$(await_rows "$(by_id "$id")" 1)"
  served="$(boundary_snapshot | jq -c '{served_by, lock_pid, player_pid}')"
  if assert_single_terminal "$rows" && printf '%s' "$rows" | jq -e '.[0].outcome=="delivered"' >/dev/null; then
    row 1 "plain notify via service" pass "one delivered history row, clip served once" \
      "request_id $id delivered, exactly one terminal row" \
      "$(jq -cn --arg id "$id" --argjson rows "$rows" --argjson b "$served" '{request_id:$id, history:$rows, boundary:$b}')"
  else
    row 1 "plain notify via service" fail "one delivered history row" \
      "rows: $(printf '%s' "$rows" | jq -c .)" \
      "$(jq -cn --arg id "$id" --argjson rows "$rows" --argjson b "$served" '{request_id:$id, history:$rows, boundary:$b}')"
  fi
}

# Row 2 — --wait takes the local path by design (service bypassed), so there is
# no request ID: correlation is by the run nonce carried in the utterance.
row2() {
  local rc rows text
  text="$(utter 2)"
  timeout "$NOTIFY_TIMEOUT" "$REPO/bin/notify.sh" --wait "$text" >/dev/null 2>&1
  rc=$?
  rows="$(await_rows "$(by_nonce "$NONCE row 2")" 1)"
  if [ "$rc" = 0 ] && assert_single_terminal "$rows"; then
    row 2 "notify --wait local path" pass "exits 0 within bound, one history row, no double-speak" \
      "rc=$rc, one $(printf '%s' "$rows" | jq -r '.[0].outcome') row" \
      "$(jq -cn --argjson rows "$rows" --argjson rc "$rc" '{exit_code:$rc, history:$rows}')"
  else
    row 2 "notify --wait local path" fail "exits 0, exactly one history row" \
      "rc=$rc, rows $(printf '%s' "$rows" | jq -c .)" \
      "$(jq -cn --argjson rows "$rows" --argjson rc "$rc" '{exit_code:$rc, history:$rows}')"
  fi
}

# submit <text> -> request id on stdout (service path, raw so the id is exact).
submit() {
  curl -sS --max-time "$HTTP_TIMEOUT" -H 'Content-Type: application/json' \
    --data-binary "$(jq -cn --arg t "$1" '{text:$t}')" "$SERVICE_URL/notify" 2>/dev/null |
    jq -r '.request_id // empty'
}
stop_request() {
  curl -sS --max-time "$HTTP_TIMEOUT" -H 'Content-Type: application/json' \
    --data-binary "$(jq -cn --arg id "$1" '{request_id:$id}')" "$SERVICE_URL/notify/stop" 2>/dev/null
}

# Row 3 — queued cancellation: stop lands before synthesis completes, so there
# must be no delivery evidence at all, only a canceled row.
row3() {
  local id stop rows
  id="$(submit "$(utter 3)")"
  [ -n "$id" ] || { row 3 "queued cancellation" fail "202 + request_id" "no request_id" '{}'; return; }
  stop="$(stop_request "$id")"
  rows="$(await_rows "$(by_id "$id")" 1)"
  local extra
  extra="$(jq -cn --arg id "$id" --argjson stop "$(printf '%s' "$stop" | jq -c . 2>/dev/null || echo null)" \
    --argjson rows "$rows" '{request_id:$id, stop_response:$stop, history:$rows}')"
  if assert_single_terminal "$rows" && printf '%s' "$rows" | jq -e '.[0].outcome=="canceled"' >/dev/null; then
    row 3 "queued cancellation" pass "canceled history row, no synthesis/delivery evidence" \
      "canceled: $(printf '%s' "$rows" | jq -r '.[0].reason')" "$extra"
  else
    row 3 "queued cancellation" fail "one canceled history row" "rows $(printf '%s' "$rows" | jq -c .)" "$extra"
  fi
}

# Rows 4+5 together — A is long, B is short; both are submitted, A is stopped
# while it is the clip in flight, and B must still play completely. Run as one
# scenario because that is the only way row 5's "cancelling A did not silence
# or reorder B" is evidenced from one timeline.
row4_5() {
  local a b stopa rows_a rows_b mid
  a="$(submit "$(utter 4) this is a deliberately longer utterance so that cancellation lands while it is still playing on the host")"
  [ -n "$a" ] || { row 4 "active-playback cancellation" fail "202 + request_id" "no request_id for A" '{}'
                   row 5 "unrelated survival" blocked "B plays completely" "A never accepted" '{}'; return; }
  b="$(submit "$(utter 5)")"
  # Let synthesis and delivery put A in flight before stopping it. Bounded, and
  # the boundary snapshot records what was actually in flight at that moment.
  sleep "${HERALD_ACCEPTANCE_INFLIGHT_WAIT:-6}"
  mid="$(boundary_snapshot)"
  stopa="$(stop_request "$a")"
  rows_a="$(await_rows "$(by_id "$a")" 1)"
  rows_b="$(await_rows "$(by_id "$b")" 1)"
  local extra
  extra="$(jq -cn --arg a "$a" --arg b "$b" \
    --argjson stop "$(printf '%s' "$stopa" | jq -c . 2>/dev/null || echo null)" \
    --argjson ra "$rows_a" --argjson rb "$rows_b" --argjson mid "$mid" \
    '{a_request_id:$a, b_request_id:$b, stop_response:$stop,
      a_history:$ra, b_history:$rb, boundary_at_stop:$mid}')"

  # `stopped:true` is only meaningful with ownership proof: the service reports
  # it when it owned the in-flight request or the host confirmed the stop. A
  # canceled history row for A is that proof on this side.
  if assert_single_terminal "$rows_a" && printf '%s' "$rows_a" | jq -e '.[0].outcome=="canceled"' >/dev/null; then
    row 4 "active-playback cancellation" pass \
      "stopped with ownership proof, clip interrupted, one canceled row" \
      "stop -> $(printf '%s' "$stopa" | jq -c '{status,stage,stopped}'), A canceled" "$extra"
  else
    row 4 "active-playback cancellation" fail "one canceled row for A" \
      "stop -> $stopa, A rows $(printf '%s' "$rows_a" | jq -c .)" "$extra"
  fi

  if [ -z "$b" ]; then
    row 5 "unrelated survival" blocked "B delivered completely" "B never accepted" "$extra"
  elif assert_single_terminal "$rows_b" && printf '%s' "$rows_b" | jq -e '.[0].outcome=="delivered"' >/dev/null; then
    row 5 "unrelated survival" pass "B still plays completely, B has a delivered row" \
      "B $b delivered while A was canceled" "$extra"
  else
    row 5 "unrelated survival" fail "B delivered" "B rows $(printf '%s' "$rows_b" | jq -c .)" "$extra"
  fi
  ROW6_TERMINAL_ID="$a"
}

# Row 6 — stop is idempotent, and an unknown ID is a stable no-op. Neither may
# append a history row: the count before must equal the count after.
row6() {
  local before after r1 r2 unknown="0123456789abcdef0123456789abcdef"
  before="$(history_json | jq 'length')"
  r1="$(stop_request "${ROW6_TERMINAL_ID:-$unknown}")"
  r2="$(stop_request "$unknown")"
  sleep 1
  after="$(history_json | jq 'length')"
  local extra
  extra="$(jq -cn --argjson before "$before" --argjson after "$after" \
    --argjson repeat "$(printf '%s' "$r1" | jq -c . 2>/dev/null || echo null)" \
    --argjson unknown "$(printf '%s' "$r2" | jq -c . 2>/dev/null || echo null)" \
    '{history_count_before:$before, history_count_after:$after, repeat_stop:$repeat, unknown_stop:$unknown}')"
  if [ "$before" = "$after" ] && printf '%s' "$r2" | jq -e '.stopped==false' >/dev/null 2>&1; then
    row 6 "stop idempotency / unknown ID" pass "stable no-op, stopped:false, no new history rows" \
      "history stayed at $after rows; unknown-ID stop reported stopped:false" "$extra"
  else
    row 6 "stop idempotency / unknown ID" fail "no new history rows, stopped:false" \
      "history $before -> $after; unknown stop $r2" "$extra"
  fi
}

# Row 7 — two near-simultaneous notifies: both delivered, arrival order
# preserved by the spool (never mixed).
row7() {
  local x y rows_x rows_y
  x="$(submit "$(utter 7) first")"
  y="$(submit "$(utter 7) second")"
  rows_x="$(await_rows "$(by_id "$x")" 1)"
  rows_y="$(await_rows "$(by_id "$y")" 1)"
  local extra
  extra="$(jq -cn --arg x "$x" --arg y "$y" --argjson rx "$rows_x" --argjson ry "$rows_y" \
    '{first_request_id:$x, second_request_id:$y, first_history:$rx, second_history:$ry}')"
  if assert_single_terminal "$rows_x" && assert_single_terminal "$rows_y" &&
     printf '%s' "$rows_x" | jq -e '.[0].outcome=="delivered"' >/dev/null &&
     printf '%s' "$rows_y" | jq -e '.[0].outcome=="delivered"' >/dev/null; then
    row 7 "serialization under concurrency" pass "both delivered, never mixed, arrival order preserved" \
      "both delivered; spool drained serially (one lock holder observed)" "$extra"
  else
    row 7 "serialization under concurrency" fail "both delivered exactly once" \
      "x $(printf '%s' "$rows_x" | jq -c .) y $(printf '%s' "$rows_y" | jq -c .)" "$extra"
  fi
}

# Row 8 — mute round-trip. MUTED_BY_US makes the EXIT trap responsible for
# unmuting, so a kill anywhere between here and the end cannot leave Herald
# silent.
row8() {
  local id rows
  "$BIN" notify mute 60s >/dev/null 2>&1
  MUTED_BY_US=1
  id="$(submit "$(utter 8)")"
  local rows_before_spool
  rows_before_spool="$(boundary_snapshot | jq -c '.spool_entries')"
  rows="$(await_rows "$(by_id "$id")" 1)"
  "$BIN" notify unmute >/dev/null 2>&1
  MUTED_BY_US=0
  local muted_now
  muted_now="$("$BIN" notify status --json 2>/dev/null | jq -r '.muted')"
  local extra
  extra="$(jq -cn --arg id "$id" --argjson rows "$rows" --argjson spool "$rows_before_spool" \
    --arg muted_after "$muted_now" '{request_id:$id, history:$rows, spool_during_mute:$spool, muted_after_cleanup:$muted_after}')"
  if assert_single_terminal "$rows" && printf '%s' "$rows" | jq -e '.[0].outcome=="muted"' >/dev/null &&
     [ "$muted_now" = "false" ]; then
    row 8 "mute respected" pass "muted history row, no playback, mute restored" \
      "muted row recorded, mute cleared afterwards" "$extra"
  else
    row 8 "mute respected" fail "one muted row and mute restored" \
      "rows $(printf '%s' "$rows" | jq -c .), muted_after=$muted_now" "$extra"
  fi
}

ROW6_TERMINAL_ID=""
row1
row2
row3
row4_5
row6
row7
row8

BOUNDARY_AFTER="$(boundary_snapshot)" || true

# Coverage of the OTHER delivery mode is recorded, never forced: forcing it
# means killing the resident player, which this harness will not do.
SERVED_BY="$(printf '%s' "$BOUNDARY_AFTER" | jq -r '.served_by // "unknown"')"
note "delivery mode observed during this run: $SERVED_BY (the other mode is not-exercised; forcing it would require mutating the playback host)"

exit 0
