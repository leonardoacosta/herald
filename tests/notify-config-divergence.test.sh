#!/usr/bin/env bash
# notify-service task 4.4 — regression test for the Amendment 2026-08-01
# divergence bypass (bin/notify.sh's "## Divergence bypass" block, task 4.3).
#
# Six cases, covering everything proposal.md's amendment paragraph and task
# 4.4's checklist call for:
#
#   1. matching caller, default SERVICE_URL   -> service is attempted
#   2. diverging caller, default SERVICE_URL  -> bypasses, delivers locally
#   3. absent file, caller matches the documented defaults -> service attempted
#      (task 4.3: "absent file compares against documented defaults")
#   4. absent file, caller diverges from the documented defaults -> bypasses,
#      delivers locally
#   5. explicit HERALD_NOTIFY_SERVICE_URL escape hatch, with a genuine
#      divergence present -> the gate never fires, service attempted anyway
#      (this is what keeps tests/notify-service.test.sh's own multi-instance
#      fixture working after this amendment)
#
# Case 1/3/5 are the non-vacuous half: each asserts the fake curl below WAS
# invoked with the expected URL, not just that no "diverges" warning printed.
# A change that disabled the service entirely (skipped straight to the local
# path in every case) would leave the curl log empty and fail exactly these
# three assertions, the way a change that stopped bypassing entirely would
# leave ssh's log empty and fail case 2/4's.
#
# ── Why a fake curl, unlike tests/notify-service.test.sh's real service ─────
# The divergence gate in bin/notify.sh only ever activates when the caller's
# resolved HERALD_NOTIFY_SERVICE_URL equals the LITERAL
# "http://127.0.0.1:8881" default (SERVICE_URL_DEFAULT is not a variable this
# test can retarget without editing bin/notify.sh, which is out of scope
# here) — and that port is not free to bind on this host: herald-notify.service
# is installed, enabled, and actively serving real traffic there, and is not
# to be stopped or reconfigured for a test. Faking `curl` on PATH intercepts
# the request before any socket opens, so cases 1/3/5 can prove "the service
# was attempted" against the real default address without a listener there
# and without ever touching production.
#
# Hermetic by construction, same discipline as tests/notify-service.test.sh:
#   - HOME and HERALD_CONFIG_DIR are always temp dirs; HERALD_STATE_DIR is
#     either unset (falls through to a temp $HOME) or an explicit temp path.
#     Leo's real state dir and ~/.config/herald/config are never read or
#     written.
#   - ssh is a fake on PATH (delivery leg), same shape as
#     tests/notify-service.test.sh's.
#   - Kokoro is a local python3 HTTP stub, reached only by the two cases that
#     fall to the local path (2 and 4); the matching/escape-hatch cases never
#     get that far.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-notify-divergence.XXXXXX)"
KOKORO_PID=""
# shellcheck disable=SC2154  # rc is assigned in this same trap string
trap 'rc=$?
  [ -n "$KOKORO_PID" ] && { kill "$KOKORO_PID" 2>/dev/null || true; wait "$KOKORO_PID" 2>/dev/null || true; }
  rm -rf "$TMP"
  exit $rc' EXIT INT TERM

[ -x "$REPO/bin/herald" ] || go build -C "$REPO" -o bin/herald ./cmd/herald

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
KOKORO_PORT="$(free_port)"
KOKORO_URL="http://127.0.0.1:$KOKORO_PORT"
ESCAPE_URL="http://127.0.0.1:$(free_port)"   # never bound; the escape-hatch case never dials it either — fake curl intercepts it too

mkdir -p "$TMP/bin"

# ── Fake curl: intercepts the service-attempt call before any socket opens ──
# Logs the exact URL requested (curl's own last positional argument) and
# answers exactly as bin/notify.sh's -w '%{http_code} %{time_connect}' format
# expects: a 202 and a nonzero time_connect is what its own "## Service
# attempt" comment block treats as REACHABLE (never fall back).
CURL_LOG="$TMP/curl.log"
: > "$CURL_LOG"
cat > "$TMP/bin/curl" <<FAKE
#!/usr/bin/env bash
url="\${*: -1}"
printf '%s\n' "\$url" >> "$CURL_LOG"
printf '202 0.001'
FAKE
chmod +x "$TMP/bin/curl"

# ── Fake ssh: delivery leg, same shape as notify-service.test.sh's ──────────
SSH_LOG="$TMP/ssh.log"
: > "$SSH_LOG"
cat > "$TMP/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
cat > /dev/null
printf 'delivered %s\n' "$(date +%s%N)" >> "$SSH_LOG"
FAKE
chmod +x "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH" SSH_LOG CURL_LOG

# ── Fake Kokoro: only reached by the two local-path cases (2 and 4) ─────────
cat > "$TMP/kokoro_fake.py" <<'PY'
import http.server
import socketserver
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/audio/speech":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        self.rfile.read(length)
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
python3 "$TMP/kokoro_fake.py" "$KOKORO_PORT" > "$TMP/kokoro.log" 2>&1 &
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

assert_one_delivered_record() {
  local history_file="$1" label="$2"
  [ -f "$history_file" ] || { echo "$label: no history record written ($history_file)" >&2; exit 1; }
  [ "$(wc -l < "$history_file" | tr -d ' ')" -eq 1 ] || {
    echo "$label: expected exactly 1 history record:" >&2; cat "$history_file" >&2; exit 1; }
  jq -e '.outcome == "delivered"' "$history_file" >/dev/null || {
    echo "$label: record is not delivered: $(cat "$history_file")" >&2; exit 1; }
}

# ── 1. Matching caller, default SERVICE_URL: service is attempted ───────────
# The caller's own resolved HERALD_STATE_DIR/HERALD_KOKORO_BASE_URL are set
# BY the shared file (bin/lib.sh sources it), so they trivially agree with
# what deployed_config_value() reads back out of that same file.
CASE1_HOME="$TMP/home1"
CASE1_CONFIG="$TMP/config1"
CASE1_STATE="$TMP/state1"
mkdir -p "$CASE1_HOME" "$CASE1_CONFIG" "$CASE1_STATE"
cat > "$CASE1_CONFIG/config" <<CONF
HERALD_STATE_DIR=$CASE1_STATE
HERALD_KOKORO_BASE_URL=$KOKORO_URL
CONF

: > "$CURL_LOG"; : > "$SSH_LOG"
env HOME="$CASE1_HOME" HERALD_CONFIG_DIR="$CASE1_CONFIG" \
  "$REPO/bin/notify.sh" "case 1: matching caller" > "$TMP/case1.out" 2>&1

grep -qx 'http://127.0.0.1:8881/notify' "$CURL_LOG" || {
  echo "case 1: expected the service to be attempted at the default URL; curl log:" >&2
  cat "$CURL_LOG" >&2; cat "$TMP/case1.out" >&2; exit 1; }
grep -q 'resolved config diverges' "$TMP/case1.out" && {
  echo "case 1: a matching config should not report divergence" >&2
  cat "$TMP/case1.out" >&2; exit 1; }
[ -s "$SSH_LOG" ] && {
  echo "case 1: the local delivery leg ran even though the service was attempted" >&2
  cat "$SSH_LOG" >&2; exit 1; }
echo "case 1 (matching, default URL): service attempted, no local fallback"

# ── 2. Diverging caller, default SERVICE_URL: bypasses, delivers locally ────
# The file declares one state dir; the caller EXPLICITLY exports a different
# one, which task 4.1's env-beats-file precedence honors — so the divergence
# here is real, not a sourcing artifact, and exercises 4.1 and 4.3 together.
CASE2_HOME="$TMP/home2"
CASE2_CONFIG="$TMP/config2"
CASE2_DEPLOYED_STATE="$TMP/state2-deployed"
CASE2_CALLER_STATE="$TMP/state2-caller"
mkdir -p "$CASE2_HOME" "$CASE2_CONFIG" "$CASE2_DEPLOYED_STATE" "$CASE2_CALLER_STATE"
cat > "$CASE2_CONFIG/config" <<CONF
HERALD_STATE_DIR=$CASE2_DEPLOYED_STATE
HERALD_KOKORO_BASE_URL=$KOKORO_URL
CONF

: > "$CURL_LOG"; : > "$SSH_LOG"
env HOME="$CASE2_HOME" HERALD_CONFIG_DIR="$CASE2_CONFIG" HERALD_STATE_DIR="$CASE2_CALLER_STATE" \
  HERALD_NOTIFY_PLAYBACK_HOST="test-host" \
  "$REPO/bin/notify.sh" "case 2: diverging caller" > "$TMP/case2.out" 2>&1

grep -q 'resolved config diverges' "$TMP/case2.out" || {
  echo "case 2: expected the divergence warning" >&2; cat "$TMP/case2.out" >&2; exit 1; }
[ -s "$CURL_LOG" ] && {
  echo "case 2: the service was attempted despite a diverging config; curl log:" >&2
  cat "$CURL_LOG" >&2; exit 1; }
[ "$(wc -l < "$SSH_LOG" | tr -d ' ')" -eq 1 ] || {
  echo "case 2: expected exactly one local delivery-leg invocation, got $(wc -l < "$SSH_LOG")" >&2; exit 1; }
assert_one_delivered_record "$CASE2_CALLER_STATE/notify.ndjson" "case 2"
echo "case 2 (diverging, default URL): bypassed the service, delivered locally"

# ── 3. Absent file, caller matches the documented defaults: service attempted
# No $HERALD_CONFIG_DIR/config at all — deployed_config_value() falls back
# to the same documented defaults (\$HOME/.local/state/herald,
# http://127.0.0.1:8880) bin/lib.sh and bin/notify.sh's own herald_config
# default to, so an unconfigured caller on a fresh host is self-consistent
# rather than exempted from the check outright (task 4.3's decision).
CASE3_HOME="$TMP/home3"
CASE3_CONFIG="$TMP/config3-absent"
mkdir -p "$CASE3_HOME"   # CASE3_CONFIG deliberately never created

: > "$CURL_LOG"; : > "$SSH_LOG"
env HOME="$CASE3_HOME" HERALD_CONFIG_DIR="$CASE3_CONFIG" \
  "$REPO/bin/notify.sh" "case 3: absent file, matches defaults" > "$TMP/case3.out" 2>&1

grep -qx 'http://127.0.0.1:8881/notify' "$CURL_LOG" || {
  echo "case 3: expected the service to be attempted at the default URL; curl log:" >&2
  cat "$CURL_LOG" >&2; cat "$TMP/case3.out" >&2; exit 1; }
grep -q 'resolved config diverges' "$TMP/case3.out" && {
  echo "case 3: a caller matching the documented defaults should not diverge" >&2
  cat "$TMP/case3.out" >&2; exit 1; }
echo "case 3 (absent file, matches defaults): service attempted"

# ── 4. Absent file, caller diverges from the documented defaults: bypasses ──
CASE4_HOME="$TMP/home4"
CASE4_CONFIG="$TMP/config4-absent"
CASE4_STATE="$TMP/state4"
mkdir -p "$CASE4_HOME" "$CASE4_STATE"   # CASE4_CONFIG deliberately never created

: > "$CURL_LOG"; : > "$SSH_LOG"
env HOME="$CASE4_HOME" HERALD_CONFIG_DIR="$CASE4_CONFIG" HERALD_STATE_DIR="$CASE4_STATE" \
  HERALD_KOKORO_BASE_URL="$KOKORO_URL" HERALD_NOTIFY_PLAYBACK_HOST="test-host" \
  "$REPO/bin/notify.sh" "case 4: absent file, diverges from defaults" > "$TMP/case4.out" 2>&1

grep -q 'resolved config diverges' "$TMP/case4.out" || {
  echo "case 4: expected the divergence warning" >&2; cat "$TMP/case4.out" >&2; exit 1; }
[ -s "$CURL_LOG" ] && {
  echo "case 4: the service was attempted despite a diverging config; curl log:" >&2
  cat "$CURL_LOG" >&2; exit 1; }
assert_one_delivered_record "$CASE4_STATE/notify.ndjson" "case 4"
echo "case 4 (absent file, diverges from defaults): bypassed the service, delivered locally"

# ── 5. Explicit SERVICE_URL escape hatch: gate never fires, despite a real
# divergence. This is what keeps tests/notify-service.test.sh passing after
# this amendment — it always points HERALD_NOTIFY_SERVICE_URL at its own
# ephemeral instance, which by construction is never the literal default.
CASE5_HOME="$TMP/home5"
CASE5_CONFIG="$TMP/config5"
CASE5_DEPLOYED_STATE="$TMP/state5-deployed"
CASE5_CALLER_STATE="$TMP/state5-caller"
mkdir -p "$CASE5_HOME" "$CASE5_CONFIG" "$CASE5_DEPLOYED_STATE" "$CASE5_CALLER_STATE"
cat > "$CASE5_CONFIG/config" <<CONF
HERALD_STATE_DIR=$CASE5_DEPLOYED_STATE
HERALD_KOKORO_BASE_URL=$KOKORO_URL
CONF

: > "$CURL_LOG"; : > "$SSH_LOG"
env HOME="$CASE5_HOME" HERALD_CONFIG_DIR="$CASE5_CONFIG" HERALD_STATE_DIR="$CASE5_CALLER_STATE" \
  HERALD_NOTIFY_SERVICE_URL="$ESCAPE_URL" \
  "$REPO/bin/notify.sh" "case 5: explicit SERVICE_URL escape hatch" > "$TMP/case5.out" 2>&1

grep -q 'resolved config diverges' "$TMP/case5.out" && {
  echo "case 5: an explicit SERVICE_URL should skip the divergence check outright" >&2
  cat "$TMP/case5.out" >&2; exit 1; }
grep -qx "$ESCAPE_URL/notify" "$CURL_LOG" || {
  echo "case 5: expected the service to be attempted at the explicit URL; curl log:" >&2
  cat "$CURL_LOG" >&2; cat "$TMP/case5.out" >&2; exit 1; }
[ -s "$SSH_LOG" ] && {
  echo "case 5: the local delivery leg ran even though the service was attempted" >&2
  cat "$SSH_LOG" >&2; exit 1; }
echo "case 5 (explicit SERVICE_URL escape hatch): gate skipped, service attempted at the explicit URL despite a real divergence"

echo "notify config divergence: matching/diverging/absent-file/escape-hatch all passed"
