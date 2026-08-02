#!/usr/bin/env bash
# notify-service task 2.2 — the fallback contract AND the race it exists to close.
#
# Three cases, in the priority order proposal.md's "## Testing" section lists them:
#
#   1. Service up   -> bin/notify.sh routes through HTTP, exactly one history record.
#   2. Service down -> bin/notify.sh routes locally and still delivers, exactly one record.
#   3. The race     -> service reachable, synthesis artificially slowed past the
#      caller's HERALD_NOTIFY_SERVICE_TIMEOUT bound, exactly one record. This is
#      "the specific race that shaped the design" (proposal.md): a synchronous
#      handler would still be inside synth+deliver+record when the response goes
#      out, so the caller's exposure window would be the FULL synthesis time
#      instead of a connection attempt.
#
# Case 3's assertion is deliberately about LATENCY, not just record count, and
# that is the point rather than a shortcut. With HERALD_NOTIFY_SERVICE_TIMEOUT set
# generous (20s, comfortably above the 3s synthesis stub below), curl always gets
# a real HTTP response rather than hitting its own --max-time first — which
# isolates the ONE thing this task exists to prove: does POST /notify return
# BEFORE synthesis finishes? A record-count-only assertion cannot tell a
# same-shaped synchronous handler apart from the async one, because
# bin/notify.sh's own connect-vs-response timeout split (task 1.7, see its
# "## Service attempt" comment block) already stops a naive client from
# double-sending even against a slow response — the response eventually lands
# and gets exactly one record either way. What a synchronous handler cannot
# hide from is TIME: send.go's own unit test proves the same property one layer
# down (TestNotifyHandlerReturnsQuicklyWhileSynthesisIsSlow, pkg/notify/send_test.go)
# by measuring httptest.ResponseRecorder latency against a stubbed-slow
# Synthesizer; this test is that property's end-to-end twin, through the real
# HTTP listener and the real bin/notify.sh client rather than Go internals.
#
# Hermetic by construction:
#   - HERALD_STATE_DIR always points at a temp dir. Leo's real state dir carries
#     471 live history records; a test that appends to it is a defect.
#   - Kokoro is a local python3 HTTP stub (POST /v1/audio/speech only), whose
#     response delay is controlled by a file the test rewrites between cases —
#     no live Kokoro container required, and case 3's slowdown is exact rather
#     than best-effort.
#   - ssh is a fake on PATH that reads stdin (the audio bytes, exactly like the
#     real remote spool's `cat > "$f"`) and exits 0. This test must not speak
#     aloud on the real playback host on every run, nor depend on that host
#     being awake — both bin/notify.sh's local delivery leg AND pkg/notify's
#     Go delivery leg (delivery.go) shell out to a program literally named
#     "ssh", so one fake on PATH covers both transports.
#   - `herald notify serve` binds loopback + this box's real tailnet address
#     (ResolveBindConfig rejects a loopback or wildcard tailnet address
#     outright — service.go's rejectWildcardOrEmpty), on a free ephemeral port
#     probed at runtime, never the systemd unit's 8881. That unit is another
#     task's deliberate end state and is neither stopped nor reconfigured here.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-notify-service.XXXXXX)"
SERVICE_PID=""
KOKORO_PID=""
# shellcheck disable=SC2154  # rc is assigned in this same trap string
trap 'rc=$?
  [ -n "$SERVICE_PID" ] && { kill "$SERVICE_PID" 2>/dev/null || true; }
  [ -n "$KOKORO_PID" ] && { kill "$KOKORO_PID" 2>/dev/null || true; }
  # wait on a SIGTERM-killed job returns 143 (128+SIGTERM) — expected, not a
  # failure to propagate; `|| true` keeps errexit from treating it as one and
  # skipping the cleanup below (it did, the first time this was written).
  [ -n "$SERVICE_PID" ] && { wait "$SERVICE_PID" 2>/dev/null || true; }
  [ -n "$KOKORO_PID" ] && { wait "$KOKORO_PID" 2>/dev/null || true; }
  rm -rf "$TMP"
  exit $rc' EXIT INT TERM

[ -x "$REPO/bin/herald" ] || go build -C "$REPO" -o bin/herald ./cmd/herald

TAILNET_IP="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$TAILNET_IP" ] || { echo "tailscale ip -4 returned nothing — serve cannot bind (proposal.md precondition)" >&2; exit 1; }

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

SERVICE_PORT="$(free_port)"
DEAD_PORT="$(free_port)"   # deliberately never bound — case 2's "unreachable"
KOKORO_PORT="$(free_port)"

# ── Fake ssh: stands in for the whole delivery leg, both transports ──────────
mkdir -p "$TMP/bin"
SSH_LOG="$TMP/ssh.log"
cat > "$TMP/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
# Consumes stdin (the audio bytes) exactly like the real remote spool script's
# `cat > "$f"` step, then exits 0. Arguments (-o BatchMode=yes, host, remote
# command) are irrelevant to a stub that never actually reaches a host.
cat > /dev/null
printf 'delivered %s\n' "$(date +%s%N)" >> "$SSH_LOG"
FAKE
chmod +x "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH" SSH_LOG

# ── Fake Kokoro: POST /v1/audio/speech only, delay read fresh per request ────
KOKORO_DELAY_FILE="$TMP/kokoro_delay"
echo 0 > "$KOKORO_DELAY_FILE"
cat > "$TMP/kokoro_fake.py" <<'PY'
import http.server
import os
import socketserver
import sys
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/audio/speech":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        self.rfile.read(length)
        delay = 0.0
        try:
            with open(os.environ["KOKORO_DELAY_FILE"]) as f:
                delay = float(f.read().strip() or "0")
        except Exception:
            pass
        time.sleep(delay)
        body = b"FAKE-KOKORO-AUDIO-NOT-REAL-MP3"
        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


port = int(sys.argv[1])
with Server(("127.0.0.1", port), Handler) as httpd:
    httpd.serve_forever()
PY
KOKORO_DELAY_FILE="$KOKORO_DELAY_FILE" python3 "$TMP/kokoro_fake.py" "$KOKORO_PORT" \
  > "$TMP/kokoro.log" 2>&1 &
KOKORO_PID=$!

wait_for_port() {
  local port="$1" tries=50
  while [ "$tries" -gt 0 ]; do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}
wait_for_port "$KOKORO_PORT" || { echo "fake kokoro never opened $KOKORO_PORT" >&2; cat "$TMP/kokoro.log" >&2; exit 1; }

# ── The real service, once, for the lifetime of the test ─────────────────────
# Loopback+tailnet, ONE state dir (ResolveStateDir reads the SERVICE process's
# own environment on every request — a client's HERALD_STATE_DIR has no effect
# on records the async worker writes, only on the LOCAL fallback path). Cases 1
# and 3 share this dir and reset its history file between them.
SERVICE_STATE="$TMP/service-state"
mkdir -p "$SERVICE_STATE"
HERALD_STATE_DIR="$SERVICE_STATE" \
HERALD_NOTIFY_PORT="$SERVICE_PORT" \
HERALD_NOTIFY_BIND_TAILSCALE_IP="$TAILNET_IP" \
HERALD_KOKORO_BASE_URL="http://127.0.0.1:$KOKORO_PORT" \
HERALD_NOTIFY_PLAYBACK_HOST="test-host" \
HERALD_NOTIFY_PLAYBACK_TIMEOUT="5" \
PATH="$PATH" SSH_LOG="$SSH_LOG" \
  "$REPO/bin/herald" notify serve > "$TMP/serve.log" 2>&1 &
SERVICE_PID=$!

wait_for_health() {
  local tries=50
  while [ "$tries" -gt 0 ]; do
    curl -sf -m 1 "http://127.0.0.1:$SERVICE_PORT/health" >/dev/null 2>&1 && return 0
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}
wait_for_health || { echo "herald notify serve never answered /health" >&2; cat "$TMP/serve.log" >&2; exit 1; }

# ── Assertion helpers ─────────────────────────────────────────────────────────

# Waits up to timeout_s for history_file to reach >=1 line, then holds an
# extra 1s and re-checks the count is still exactly 1 — catching a DELAYED
# second write (a late double-send), not just an immediate one. Prints the
# settled count.
assert_exactly_one_record() {
  local history_file="$1" timeout_s="$2" deadline
  deadline=$(( $(date +%s) + timeout_s ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$history_file" ] && [ "$(wc -l < "$history_file" | tr -d ' ')" -ge 1 ]; then
      break
    fi
    sleep 0.1
  done
  [ -f "$history_file" ] || { echo "no history record appeared within ${timeout_s}s: $history_file" >&2; return 1; }
  sleep 1
  local n
  n="$(wc -l < "$history_file" | tr -d ' ')"
  [ "$n" -eq 1 ] || { echo "expected exactly 1 history record, got $n:" >&2; cat "$history_file" >&2; return 1; }
  return 0
}

# ── 1. Service up: routes through HTTP ────────────────────────────────────────
rm -f "$SERVICE_STATE/notify.ndjson"
LOCAL_STATE1="$TMP/local-state-1"
mkdir -p "$LOCAL_STATE1"
: > "$SSH_LOG"
env \
  HERALD_STATE_DIR="$LOCAL_STATE1" \
  HERALD_NOTIFY_SERVICE_URL="http://127.0.0.1:$SERVICE_PORT" \
  HERALD_KOKORO_BASE_URL="http://127.0.0.1:$KOKORO_PORT" \
  HERALD_NOTIFY_PLAYBACK_HOST="test-host" \
  "$REPO/bin/notify.sh" "case one: service is up" > "$TMP/case1.out" 2>&1

grep -q 'service accepted' "$TMP/case1.out" || {
  echo "case 1: bin/notify.sh did not report routing through the service" >&2
  cat "$TMP/case1.out" >&2; exit 1; }
grep -q 'falling back' "$TMP/case1.out" && {
  echo "case 1: bin/notify.sh fell back with the service up" >&2
  cat "$TMP/case1.out" >&2; exit 1; }

assert_exactly_one_record "$SERVICE_STATE/notify.ndjson" 5 || exit 1
jq -e '.outcome == "delivered"' "$SERVICE_STATE/notify.ndjson" >/dev/null || {
  echo "case 1: record is not delivered: $(cat "$SERVICE_STATE/notify.ndjson")" >&2; exit 1; }
[ "$(wc -l < "$SSH_LOG" | tr -d ' ')" -eq 1 ] || {
  echo "case 1: expected exactly one delivery leg invocation, got $(wc -l < "$SSH_LOG")" >&2; exit 1; }
[ -s "$LOCAL_STATE1/notify.ndjson" ] 2>/dev/null && {
  echo "case 1: the local fallback path ALSO wrote a record — double-send" >&2
  cat "$LOCAL_STATE1/notify.ndjson" >&2; exit 1; }

echo "case 1 (service up): routed through HTTP, exactly one delivered record"

# ── 2. Service down: routes locally, still delivers ───────────────────────────
LOCAL_STATE2="$TMP/local-state-2"
mkdir -p "$LOCAL_STATE2"
: > "$SSH_LOG"
env \
  HERALD_STATE_DIR="$LOCAL_STATE2" \
  HERALD_NOTIFY_SERVICE_URL="http://127.0.0.1:$DEAD_PORT" \
  HERALD_KOKORO_BASE_URL="http://127.0.0.1:$KOKORO_PORT" \
  HERALD_NOTIFY_PLAYBACK_HOST="test-host" \
  "$REPO/bin/notify.sh" "case two: service is down" > "$TMP/case2.out" 2>&1

grep -q 'falling back to the local path' "$TMP/case2.out" || {
  echo "case 2: bin/notify.sh did not report falling back" >&2
  cat "$TMP/case2.out" >&2; exit 1; }
grep -q 'notify: delivered' "$TMP/case2.out" || {
  echo "case 2: the local path did not report delivery" >&2
  cat "$TMP/case2.out" >&2; exit 1; }

assert_exactly_one_record "$LOCAL_STATE2/notify.ndjson" 5 || exit 1
jq -e '.outcome == "delivered"' "$LOCAL_STATE2/notify.ndjson" >/dev/null || {
  echo "case 2: record is not delivered: $(cat "$LOCAL_STATE2/notify.ndjson")" >&2; exit 1; }
[ "$(wc -l < "$SSH_LOG" | tr -d ' ')" -eq 1 ] || {
  echo "case 2: expected exactly one delivery leg invocation, got $(wc -l < "$SSH_LOG")" >&2; exit 1; }

echo "case 2 (service down): routed locally, exactly one delivered record"

# ── 3. The race: reachable, synthesis slowed past the caller's bound ─────────
SLOW_SECS=3
FAST_BOUND_MS=1500   # generous under SLOW_SECS*1000=3000, generous over process-start noise
rm -f "$SERVICE_STATE/notify.ndjson"
LOCAL_STATE3="$TMP/local-state-3"
mkdir -p "$LOCAL_STATE3"
: > "$SSH_LOG"
echo "$SLOW_SECS" > "$KOKORO_DELAY_FILE"

START_NS="$(date +%s%N)"
env \
  HERALD_STATE_DIR="$LOCAL_STATE3" \
  HERALD_NOTIFY_SERVICE_URL="http://127.0.0.1:$SERVICE_PORT" \
  HERALD_NOTIFY_SERVICE_TIMEOUT="20" \
  HERALD_KOKORO_BASE_URL="http://127.0.0.1:$KOKORO_PORT" \
  HERALD_NOTIFY_PLAYBACK_HOST="test-host" \
  "$REPO/bin/notify.sh" "case three: synthesis is slow" > "$TMP/case3.out" 2>&1
END_NS="$(date +%s%N)"
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))

echo 0 > "$KOKORO_DELAY_FILE"   # restore before the poll below issues its own requests

grep -q 'service accepted' "$TMP/case3.out" || {
  echo "case 3: bin/notify.sh did not report routing through the service" >&2
  cat "$TMP/case3.out" >&2; exit 1; }

# THE assertion this task exists to make fail against a synchronous endpoint:
# the call returned in well under the ${SLOW_SECS}s synthesis stub, proving
# POST /notify answered before synthesis finished rather than after.
[ "$ELAPSED_MS" -lt "$FAST_BOUND_MS" ] || {
  echo "case 3: bin/notify.sh took ${ELAPSED_MS}ms against a ${SLOW_SECS}s synthesis stub — the endpoint is not returning before synthesis finishes (a synchronous handler regression)" >&2
  cat "$TMP/case3.out" >&2; exit 1; }

assert_exactly_one_record "$SERVICE_STATE/notify.ndjson" $((SLOW_SECS + 5)) || exit 1
jq -e '.outcome == "delivered"' "$SERVICE_STATE/notify.ndjson" >/dev/null || {
  echo "case 3: record is not delivered: $(cat "$SERVICE_STATE/notify.ndjson")" >&2; exit 1; }
[ "$(wc -l < "$SSH_LOG" | tr -d ' ')" -eq 1 ] || {
  echo "case 3: expected exactly one delivery leg invocation, got $(wc -l < "$SSH_LOG")" >&2; exit 1; }
[ -s "$LOCAL_STATE3/notify.ndjson" ] 2>/dev/null && {
  echo "case 3: the local fallback path ALSO wrote a record — double-send" >&2
  cat "$LOCAL_STATE3/notify.ndjson" >&2; exit 1; }

echo "case 3 (slow synthesis): returned in ${ELAPSED_MS}ms against a ${SLOW_SECS}s stub, exactly one delivered record"

echo "notify service: service-up, service-down, and slow-synthesis race all passed"
