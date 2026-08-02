#!/usr/bin/env bash
# notify-service task 2.3 — the STOP condition's runtime guard.
#
# proposal.md `## STOP conditions`: "The listener binding anything broader
# than loopback + the tailnet address" is a report-don't-paper-over
# condition. Task 1.4 already unit-tests the CONFIG that guards against this
# (TestBindConfigNeverIncludesAWildcardAddress, TestResolveBindConfig* in
# pkg/notify/service_test.go) — those prove ResolveBindConfig can never
# PRODUCE a wildcard. They never start a real listener and never prove a
# third interface is actually unreachable. This test is the complementary
# runtime assertion: a live `herald notify serve` process, answering on
# loopback and the real tailnet address, refused on a third real interface —
# in the same run against the same process, so a listener that silently
# widened its bind (or never came up at all) fails this test rather than
# passing by omission.
#
# Own file rather than a fourth case in notify-service.test.sh: that file's
# hermetic fixture (fake Kokoro, fake ssh, HERALD_NOTIFY_SERVICE_TIMEOUT
# race) exists entirely to test the FALLBACK CONTRACT — POST /notify content
# and timing. This assertion never calls /notify, needs no synthesis or
# delivery stub, and instead needs something that file deliberately has
# none of: real interface addresses (tailnet + LAN) resolved from the host's
# actual network config. Bolting that onto notify-service.test.sh would mix
# two unrelated fixture shapes in one file for no reuse payback.
#
# Isolation:
#   - HERALD_STATE_DIR always points at a temp dir. Leo's real state dir
#     carries 471 live history records; a test that touches it is a defect.
#   - The service binds on a free ephemeral port probed at runtime, never
#     the systemd unit's 8881. That unit is another task's deliberate end
#     state and is neither stopped nor reconfigured here.
#   - No baked-in host addresses (AGENTS.md ground rules): the tailnet
#     address comes from `tailscale ip -4` and the third-interface address
#     is resolved from `ip -4 -o addr show scope global` at runtime, never
#     hardcoded.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-notify-bind.XXXXXX)"
SERVICE_PID=""
# shellcheck disable=SC2154  # rc is assigned in this same trap string
trap 'rc=$?
  [ -n "$SERVICE_PID" ] && { kill "$SERVICE_PID" 2>/dev/null || true; }
  [ -n "$SERVICE_PID" ] && { wait "$SERVICE_PID" 2>/dev/null || true; }
  rm -rf "$TMP"
  exit $rc' EXIT INT TERM

[ -x "$REPO/bin/herald" ] || go build -C "$REPO" -o bin/herald ./cmd/herald

TAILNET_IP="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$TAILNET_IP" ] || { echo "tailscale ip -4 returned nothing — serve cannot bind (proposal.md precondition)" >&2; exit 1; }

# A real, currently-assigned interface address that is neither the tailnet
# address nor loopback. Excludes Docker/bridge/veth interfaces so the result
# is a genuine LAN-facing address (this host's is 192.168.1.100 on eth0/
# wlan0) rather than an internal bridge nothing external ever reaches —
# resolved fresh each run, never hardcoded.
THIRD_IP="$(ip -4 -o addr show scope global \
  | awk '{print $2, $4}' \
  | grep -Ev '^(br-|docker|veth|tailscale)' \
  | awk '{print $2}' \
  | cut -d/ -f1 \
  | grep -v "^${TAILNET_IP}$" \
  | sort -u \
  | head -1 || true)"

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
SERVICE_PORT="$(free_port)"

SERVICE_STATE="$TMP/service-state"
mkdir -p "$SERVICE_STATE"
HERALD_STATE_DIR="$SERVICE_STATE" \
HERALD_NOTIFY_PORT="$SERVICE_PORT" \
HERALD_NOTIFY_BIND_TAILSCALE_IP="$TAILNET_IP" \
  "$REPO/bin/herald" notify serve > "$TMP/serve.log" 2>&1 &
SERVICE_PID=$!

wait_for_health() {
  local addr="$1" tries=50
  while [ "$tries" -gt 0 ]; do
    curl -sf -m 1 "http://$addr:$SERVICE_PORT/health" >/dev/null 2>&1 && return 0
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}
wait_for_health "127.0.0.1" || { echo "herald notify serve never answered on loopback" >&2; cat "$TMP/serve.log" >&2; exit 1; }

# ── 1. Reachable on loopback ──────────────────────────────────────────────
LOOPBACK_CODE="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$SERVICE_PORT/health")"
[ "$LOOPBACK_CODE" = "200" ] || {
  echo "loopback: GET /health = $LOOPBACK_CODE, want 200" >&2; exit 1; }
echo "loopback (127.0.0.1:$SERVICE_PORT): reachable, /health = 200"

# ── 2. Reachable on the tailnet address ───────────────────────────────────
TAILNET_CODE="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://$TAILNET_IP:$SERVICE_PORT/health")"
[ "$TAILNET_CODE" = "200" ] || {
  echo "tailnet ($TAILNET_IP:$SERVICE_PORT): GET /health = $TAILNET_CODE, want 200" >&2; exit 1; }
echo "tailnet ($TAILNET_IP:$SERVICE_PORT): reachable, /health = 200"

# ── 3. Refused on a third interface ───────────────────────────────────────
# Skips cleanly on a single-interface host rather than silently passing —
# an absent THIRD_IP proves nothing about bind posture either way.
if [ -z "$THIRD_IP" ]; then
  echo "SKIP: no third global interface address found on this host besides the tailnet address ($TAILNET_IP) — bind-posture refusal not exercised"
else
  curl_rc=0
  curl -s -o /dev/null -m 2 "http://$THIRD_IP:$SERVICE_PORT/health" || curl_rc=$?
  # curl exit 7 = "Failed to connect to host" i.e. connection refused — the
  # OS actively rejected the SYN because nothing is listening on that exact
  # address:port. Any other outcome (0 = it answered, or e.g. 28 = timed
  # out reaching an address that isn't even locally assigned) is not proof
  # of a scoped bind and must fail this test rather than pass vacuously.
  [ "$curl_rc" -eq 7 ] || {
    echo "third interface ($THIRD_IP:$SERVICE_PORT): curl exit $curl_rc, want 7 (connection refused) — listener may be bound wider than loopback + tailnet" >&2
    exit 1; }
  echo "third interface ($THIRD_IP:$SERVICE_PORT): refused (curl exit 7 — connection refused), while loopback and tailnet answered in this same run"
fi

# ── 4. No wildcard bind ───────────────────────────────────────────────────
SS_LINES="$(ss -ltn "sport = :$SERVICE_PORT")"
echo "$SS_LINES" | grep -Eq '(^| )0\.0\.0\.0:'"$SERVICE_PORT"'( |$)' && {
  echo "ss shows a 0.0.0.0:$SERVICE_PORT wildcard bind — STOP condition violated:" >&2
  echo "$SS_LINES" >&2; exit 1; }
echo "$SS_LINES" | grep -Eq '(^| )(\*|\[?::\]?):'"$SERVICE_PORT"'( |$)' && {
  echo "ss shows a wildcard bind (*/:: on $SERVICE_PORT) — STOP condition violated:" >&2
  echo "$SS_LINES" >&2; exit 1; }
BOUND_COUNT="$(echo "$SS_LINES" | grep -c "LISTEN.*:$SERVICE_PORT" || true)"
[ "$BOUND_COUNT" -eq 2 ] || {
  echo "expected exactly 2 bound addresses for port $SERVICE_PORT, ss shows $BOUND_COUNT:" >&2
  echo "$SS_LINES" >&2; exit 1; }
echo "ss -ltn: exactly 2 addresses bound on port $SERVICE_PORT, no wildcard"
echo "$SS_LINES"

echo "notify bind posture: loopback and tailnet reachable, third interface refused, no wildcard bind"
