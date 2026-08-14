#!/usr/bin/env bash
# acceptance-cancellation.test.sh — tests for the acceptance harness itself.
#
# The harness is verification tooling, so its own failure modes are the thing
# to test: does gate 0 abort on a stale deployment BEFORE any audio, does a
# non-live run stay silent, and does the evidence report keep the shape a
# consumer can rely on.
#
# Deliberately NOT tested here: the live matrix. Exercising it means playing
# real audio on the playback host, which is exactly what --live exists to gate
# behind an operator's authorization — a test suite must not be able to make
# the house talk.
#
# Non-live runs are safe against the deployed service by construction: without
# --live the harness only reads /health, posts two DELIBERATELY INVALID bodies
# (rejected at 400 before any queueing), and stops one unknown request ID
# (a no-op). None of those synthesize, deliver, or append a history row.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$REPO/tests/acceptance-cancellation.sh"
TMP="$(mktemp -d -t herald-acceptance-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

# ── 1. Syntax ────────────────────────────────────────────────────────────────
bash -n "$HARNESS" || fail "bash -n"
[ -x "$HARNESS" ] || fail "harness is not executable"
pass "harness parses and is executable"

# ── 2. It is explicit-only ───────────────────────────────────────────────────
# The one structural guarantee that cannot be re-derived at runtime: nothing
# in the repo may invoke this harness automatically. If a hook, a unit, or a
# plugin command ever references it, this fails.
CALLERS="$(grep -rl 'acceptance-cancellation' "$REPO" \
  --include='*.sh' --include='*.go' --include='*.md' --include='*.json' --include='*.service' \
  2>/dev/null | grep -v '^'"$REPO"'/tests/acceptance-cancellation' | grep -v '/openspec/' | grep -v '/docs/' || true)"
[ -z "$CALLERS" ] || fail "harness is referenced by non-doc callers (must stay explicit-only): $CALLERS"
pass "harness has no automatic callers (explicit-only)"

# ── 3. Gate 0 aborts on a stale deployment, without audio ────────────────────
# Induced non-destructively: HERALD_ACCEPTANCE_BIN points at a STUB that
# reports a different version than the running service. The deployed binary,
# the unit, and the config file are all untouched.
STUB="$TMP/herald-stale"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Minimal stand-in for `herald`: answers `notify status --json` with a version
# that cannot match whatever the running service reports.
case "$*" in
  *"status --json"*) echo '{"version":"stale-0000000","state_dir":"/nonexistent","muted":false}' ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

STALE_OUT="$TMP/stale.json"
set +e
HERALD_ACCEPTANCE_BIN="$STUB" "$HARNESS" --out "$STALE_OUT" >"$TMP/stale.log" 2>&1
STALE_RC=$?
set -e

if [ ! -f "$STALE_OUT" ]; then
  # No deployed service on this box: gate 0 fails for a different reason and
  # the mismatch assertion has nothing to prove. Report honestly rather than
  # passing a check that never ran.
  cat "$TMP/stale.log" >&2
  fail "no report written — the harness must always write one"
fi
[ "$STALE_RC" -ne 0 ] || fail "gate 0 must exit non-zero on a stale deployment"
jq -e '.alignment.passed == false' "$STALE_OUT" >/dev/null || fail "alignment must report passed:false"
jq -e '.verdict == "fail"' "$STALE_OUT" >/dev/null || fail "a failed gate 0 must yield verdict fail"
jq -e '[.rows[] | select(.status=="pass")] | length == 0' "$STALE_OUT" >/dev/null ||
  fail "no row may pass when gate 0 failed"
# The remediation has to be named, and the harness must not have restarted it.
jq -e '.alignment.reasons | join(" ") | test("service-sync")' "$STALE_OUT" >/dev/null ||
  fail "a stale service must be reported with its remediation (bin/service-sync.sh)"
# Statically, not from the log: the log legitimately CONTAINS the word
# "restart" in its own remediation text ("re-run bin/service-sync.sh"), so what
# is checked is that the harness never ISSUES a lifecycle command. Comment
# lines are stripped first for the same reason — naming the remediation in
# prose is the documented behavior, not a violation.
if sed 's/#.*//' "$HARNESS" |
  grep -Eq 'systemctl[^|)]*(restart|reload|enable|disable)|launchctl|pkill|killall|kill +-'; then
  fail "harness contains a service/player lifecycle mutation"
fi
# systemctl appears at all only as the read-only is-active probe.
if sed 's/#.*//' "$HARNESS" | grep -o 'systemctl[^"]*' | grep -qv 'is-active'; then
  fail "harness uses systemctl for something other than the is-active probe"
fi
# Every remote call is a read.
if sed 's/#.*//' "$HARNESS" | grep -Eq 'ssh .*(rm |mv |kill|launchctl|touch |> )'; then
  fail "harness issues a write over ssh to the playback host"
fi
pass "gate 0 aborts on an induced version mismatch, names the remediation, plays nothing"

# ── 4. Non-live run: report shape, silence, cleanup ──────────────────────────
# Requires a healthy deployed service; skipped (not silently passed) otherwise.
if ! curl -fsS --max-time 3 "http://127.0.0.1:${HERALD_NOTIFY_PORT:-8881}/health" >/dev/null 2>&1; then
  echo "skip — no deployed service on this host; non-live report-shape checks not exercised" >&2
  exit 0
fi

OUT="$TMP/run.json"
set +e
"$HARNESS" --out "$OUT" > "$TMP/run.log" 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] || { cat "$TMP/run.log" >&2; fail "non-live run against a healthy service should exit 0"; }
[ -f "$OUT" ] || fail "no report written"

# Documented report shape (proposal.md "Telemetry / history requirements").
jq -e '
  .schema == "herald.acceptance.v1"
  and (.run_ts | type == "string")
  and (.nonce | type == "string")
  and .live == false
  and (.duration_s | type == "number")
  and (.alignment | has("running_version") and has("ondisk_version")
       and has("config_digest") and has("passed") and has("reasons"))
  and (.boundary | has("before") and has("after"))
  and (.rows | type == "array" and length > 0)
  and (.rows | all(.status == "pass" or .status == "fail"
                   or .status == "blocked" or .status == "not-exercised"))
  and (.rows | all(has("row") and has("name") and has("expected")
                   and has("observed") and has("evidence")))
  and (.verdict == "pass" or .verdict == "fail" or .verdict == "partial")
  and (.not_exercised | type == "array")
' "$OUT" >/dev/null || { jq . "$OUT" >&2; fail "report does not match the documented shape"; }
pass "evidence report matches the documented shape"

# A non-live run never claims a pass it did not earn.
jq -e '.verdict == "partial" and (.not_exercised | length > 0)' "$OUT" >/dev/null ||
  fail "a non-live run must be partial with the unexercised rows listed"
pass "non-live verdict is partial, unexercised rows listed"

# No secret values, no config dump: the report carries a DIGEST of the shared
# config file and none of its values beyond the non-secret ones notify status
# already surfaces.
CONFIG_FILE="${HERALD_CONFIG_DIR:-$HOME/.config/herald}/config"
if [ -r "$CONFIG_FILE" ]; then
  jq -e '.alignment.config_digest | test("^[0-9a-f]{64}$|^absent$")' "$OUT" >/dev/null ||
    fail "config_digest must be a sha256 digest, not contents"
fi
grep -Eqi '(password|secret|token|api[_-]?key)' "$OUT" && fail "report contains a secret-looking key"
pass "report carries digests, not secrets"

# Silence: no history row anywhere carries this run's nonce.
NONCE="$(jq -r .nonce "$OUT")"
BIN="$REPO/bin/herald"
if [ -x "$BIN" ]; then
  if "$BIN" notify history --json -n 100 2>/dev/null | jq -e --arg n "$NONCE" \
      'any(.[]; (.text // "") | test($n))' >/dev/null 2>&1; then
    fail "a non-live run appended a history row (it must play and record nothing)"
  fi
  # And it did not leave Herald muted.
  "$BIN" notify status --json 2>/dev/null | jq -e '.muted == false' >/dev/null ||
    fail "harness left Herald muted"
fi
pass "non-live run played nothing, recorded nothing, left mute off"

echo "acceptance-cancellation.test.sh: all checks passed"
