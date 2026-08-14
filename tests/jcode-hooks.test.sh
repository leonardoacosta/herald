#!/usr/bin/env bash
# jcode-hooks.test.sh — jcode-native-integration tasks 4.1 / 4.2.
#
# Two halves, both hermetic:
#
#   A. Adapter behaviour (turn-end.sh, session-end.sh) under a synthetic
#      JCODE_HOOK_* env, with a FAKE notify.sh in a temp $HERALD so nothing
#      is ever synthesized, spoken, or written to Leo's real state dir. The
#      fake logs one line per invocation, standing in for the one history
#      record `bin/notify.sh` would append.
#
#   B. Installer round-trip against a fixture config.toml modelled on the
#      real ~/.jcode/config.toml [hooks] table (herdr wiring present):
#      install twice -> byte-identical; --remove -> restores the fixture
#      exactly.
# shellcheck disable=SC2015  # `check && ok || bad` is the intended assertion shape here
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-jcode-hooks.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

# ── Fake herald root: real adapters, fake pipe ─────────────────────────────
FAKE_HERALD="$TMP/herald"
mkdir -p "$FAKE_HERALD/bin" "$FAKE_HERALD/plugin/jcode/hooks"
cp "$REPO/plugin/jcode/hooks/turn-end.sh" "$REPO/plugin/jcode/hooks/session-end.sh" \
   "$FAKE_HERALD/plugin/jcode/hooks/"
chmod +x "$FAKE_HERALD/plugin/jcode/hooks/"*.sh
NOTIFY_LOG="$TMP/notify.log"
: > "$NOTIFY_LOG"
cat > "$FAKE_HERALD/bin/notify.sh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NOTIFY_LOG"
exit 0
FAKE
chmod +x "$FAKE_HERALD/bin/notify.sh"

TURN_END="$FAKE_HERALD/plugin/jcode/hooks/turn-end.sh"
SESSION_END="$FAKE_HERALD/plugin/jcode/hooks/session-end.sh"

count() { wc -l < "$NOTIFY_LOG" | tr -d ' '; }

run_turn() {
  # run_turn <duration_ms> [extra env assignments...]
  local dur="$1"; shift
  env HERALD="$FAKE_HERALD" \
      JCODE_HOOK_EVENT=turn_end \
      JCODE_HOOK_SESSION_ID=test-session \
      JCODE_HOOK_CWD="$TMP/myproject" \
      JCODE_HOOK_STATUS=ok \
      JCODE_HOOK_DURATION_MS="$dur" \
      JCODE_HOOK_LAST_ASSISTANT_TEXT="did the thing" \
      "$@" "$TURN_END"
}

echo "A. adapter behaviour"

# 4.1a: above threshold -> exactly one delegation (one history record).
: > "$NOTIFY_LOG"
run_turn 60000; rc=$?
[ "$rc" -eq 0 ] || bad "above-threshold exit $rc (must be 0)"
[ "$(count)" = "1" ] && ok "above threshold delegates exactly once" \
  || bad "above threshold: expected 1 delegation, got $(count)"
grep -q "myproject" "$NOTIFY_LOG" \
  && ok "summary carries the project name" \
  || bad "summary missing project name: $(cat "$NOTIFY_LOG")"

# 4.1b: below threshold -> silence.
: > "$NOTIFY_LOG"
run_turn 1000; rc=$?
[ "$rc" -eq 0 ] || bad "below-threshold exit $rc (must be 0)"
[ "$(count)" = "0" ] && ok "below threshold stays silent" \
  || bad "below threshold: expected 0 delegations, got $(count)"

# threshold is tunable
: > "$NOTIFY_LOG"
run_turn 1000 HERALD_JCODE_MIN_TURN_MS=500 >/dev/null
[ "$(count)" = "1" ] && ok "HERALD_JCODE_MIN_TURN_MS lowers the gate" \
  || bad "custom threshold ignored"

# error status wording
: > "$NOTIFY_LOG"
env HERALD="$FAKE_HERALD" JCODE_HOOK_EVENT=turn_end JCODE_HOOK_STATUS=error \
    JCODE_HOOK_DURATION_MS=60000 JCODE_HOOK_CWD="$TMP/myproject" \
    JCODE_HOOK_LAST_ASSISTANT_TEXT="boom" "$TURN_END"
grep -q "error" "$NOTIFY_LOG" && ok "error status is spoken as an error" \
  || bad "error status not reflected: $(cat "$NOTIFY_LOG")"

# empty assistant text -> silence
: > "$NOTIFY_LOG"
env HERALD="$FAKE_HERALD" JCODE_HOOK_EVENT=turn_end JCODE_HOOK_STATUS=ok \
    JCODE_HOOK_DURATION_MS=60000 JCODE_HOOK_LAST_ASSISTANT_TEXT="" "$TURN_END"
[ "$(count)" = "0" ] && ok "empty assistant text stays silent" \
  || bad "empty assistant text produced a notification"

# 4.1c: herald missing -> exit 0, silent. HERALD points at a dir with no pipe;
# the self-location fallback must not rescue a deliberately broken root.
: > "$NOTIFY_LOG"
set +e
env HERALD="$TMP/nonexistent" JCODE_HOOK_EVENT=turn_end JCODE_HOOK_STATUS=ok \
    JCODE_HOOK_DURATION_MS=60000 JCODE_HOOK_LAST_ASSISTANT_TEXT="x" "$TURN_END"
rc=$?
set -e
[ "$rc" -eq 0 ] && [ "$(count)" = "0" ] \
  && ok "missing herald pipe: exit 0, silent" \
  || bad "missing herald pipe: exit $rc, $(count) delegations"

# session-end default off / opt-in on
: > "$NOTIFY_LOG"
env HERALD="$FAKE_HERALD" JCODE_HOOK_EVENT=session_end JCODE_HOOK_CWD="$TMP/myproject" \
    "$SESSION_END"
[ "$(count)" = "0" ] && ok "session_end is default-off" \
  || bad "session_end fired without opt-in"
env HERALD="$FAKE_HERALD" HERALD_JCODE_SESSION_END=1 JCODE_HOOK_EVENT=session_end \
    JCODE_HOOK_CWD="$TMP/myproject" "$SESSION_END"
[ "$(count)" = "1" ] && ok "session_end fires when opted in" \
  || bad "session_end opt-in did not fire"

echo "B. installer round-trip"

FIXTURE="$TMP/config.fixture.toml"
cat > "$FIXTURE" <<'TOML'
[general]
model = "test"

[hooks]
turn_start = "/opt/herdr/jcode-herdr-agent-state.sh session"
turn_end = "/opt/herdr/jcode-herdr-agent-state.sh session"
session_start = "/opt/herdr/jcode-herdr-agent-state.sh session"
session_end = "/opt/herdr/jcode-herdr-agent-state.sh session"
pre_tool_timeout_ms = 5000

[ambient]
enabled = false
TOML

CFG="$TMP/config.toml"
cp "$FIXTURE" "$CFG"

JCODE_CONFIG="$CFG" "$REPO/plugin/jcode/install.sh" >/dev/null
cp "$CFG" "$TMP/after-first.toml"
JCODE_CONFIG="$CFG" "$REPO/plugin/jcode/install.sh" >/dev/null
if cmp -s "$CFG" "$TMP/after-first.toml"; then
  ok "install is byte-identical on the second run"
else
  bad "install is not idempotent"; diff "$TMP/after-first.toml" "$CFG" || true
fi

grep -q "plugin/jcode/hooks/turn-end.sh" "$CFG" \
  && ok "turn_end wired to herald's adapter" || bad "turn_end not wired"
grep -q "plugin/jcode/hooks/session-end.sh" "$CFG" \
  && ok "session_end wired to herald's adapter" || bad "session_end not wired"
grep -q "jcode-herdr-agent-state.sh" "$CFG" \
  && ok "existing herdr wiring preserved" || bad "herdr wiring lost"
grep -q "^turn_start = " "$CFG" \
  && ok "unrelated hook keys untouched" || bad "turn_start key mangled"
python3 -c "import tomllib,sys; tomllib.load(open('$CFG','rb'))" \
  && ok "result is valid TOML" || bad "result is not valid TOML"

JCODE_CONFIG="$CFG" "$REPO/plugin/jcode/install.sh" --status >/dev/null \
  && ok "--status runs clean" || bad "--status failed"

JCODE_CONFIG="$CFG" "$REPO/plugin/jcode/install.sh" --remove >/dev/null
if cmp -s "$CFG" "$FIXTURE"; then
  ok "--remove restores the fixture exactly"
else
  bad "--remove did not restore the fixture"; diff "$FIXTURE" "$CFG" || true
fi

# Array-shaped fixture: herald appends a member, remove drops only it.
ARRFIX="$TMP/config.array.toml"
cat > "$ARRFIX" <<'TOML'
[hooks]
turn_end = ["/opt/a.sh", "/opt/b.sh"]
TOML
CFG2="$TMP/config2.toml"
cp "$ARRFIX" "$CFG2"
JCODE_CONFIG="$CFG2" "$REPO/plugin/jcode/install.sh" >/dev/null
python3 - "$CFG2" <<'PY' && ok "array-shaped hook: herald appended, others kept" || bad "array-shaped hook mishandled"
import sys, tomllib
h = tomllib.load(open(sys.argv[1], 'rb'))["hooks"]["turn_end"]
assert h[:2] == ["/opt/a.sh", "/opt/b.sh"], h
assert len(h) == 3 and "plugin/jcode/hooks/turn-end.sh" in h[2], h
PY
JCODE_CONFIG="$CFG2" "$REPO/plugin/jcode/install.sh" --remove >/dev/null
python3 - "$CFG2" <<'PY' && ok "array-shaped hook: remove drops only herald" || bad "array remove wrong"
import sys, tomllib
h = tomllib.load(open(sys.argv[1], 'rb'))["hooks"]["turn_end"]
assert h == ["/opt/a.sh", "/opt/b.sh"], h
PY

# Missing [hooks] table -> fail loud (install is interactive).
echo '[general]' > "$TMP/nohooks.toml"
set +e
JCODE_CONFIG="$TMP/nohooks.toml" "$REPO/plugin/jcode/install.sh" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] && ok "missing [hooks] table fails loud" || bad "missing [hooks] silently accepted"

# Unparsable [hooks] entry -> fail loud, config untouched.
printf '[hooks]\nturn_end = "unterminated\n' > "$TMP/bad.toml"
cp "$TMP/bad.toml" "$TMP/bad.orig"
set +e
JCODE_CONFIG="$TMP/bad.toml" "$REPO/plugin/jcode/install.sh" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] && cmp -s "$TMP/bad.toml" "$TMP/bad.orig" \
  && ok "unparsable [hooks] fails loud and leaves config untouched" \
  || bad "unparsable [hooks] not handled (exit $rc)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
