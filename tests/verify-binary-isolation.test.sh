#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REAL_PATH="$PATH"
TMP="$(mktemp -d -t herald-verify-isolation.XXXXXX)"
TMPDIR="$TMP/tmp"
mkdir -p "$TMPDIR" "$TMP/repo/bin" "$TMP/home"
export TMPDIR
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tar --exclude=.git --exclude=node_modules -cf - -C "$REPO" . | tar -xf - -C "$TMP/repo"
SENTINEL="$TMP/repo/bin/herald"
SENTINEL_LOG="$TMP/sentinel.log"
cat > "$SENTINEL" <<'SENTINEL'
#!/usr/bin/env bash
echo "$*" >> "$SENTINEL_LOG"
exit 97
SENTINEL
chmod +x "$SENTINEL"
before="$(sha256sum "$SENTINEL" | cut -d' ' -f1)"

rc=0
env HERALD_VERIFY_ISOLATION_CHILD=1 HOME="$TMP/home" GOMODCACHE="$(go env GOMODCACHE)" GOCACHE="$(go env GOCACHE)" SENTINEL_LOG="$SENTINEL_LOG" /usr/bin/timeout 180s bash "$TMP/repo/bin/verify.sh" >"$TMP/verify.out" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/verify.out" >&2; exit "$rc"; }
[ ! -s "$SENTINEL_LOG" ] || { echo "canonical gate invoked deployed sentinel" >&2; cat "$SENTINEL_LOG" >&2; exit 1; }
after="$(sha256sum "$SENTINEL" | cut -d' ' -f1)"
[ "$before" = "$after" ] || { echo "canonical gate changed bin/herald sentinel" >&2; exit 1; }
grep -q 'verification: all Go and hermetic shell tests passed' "$TMP/verify.out"

# Deliver TERM from a build subprocess to its verifier parent. Bash handles
# the pending trap as soon as the child returns, then its EXIT trap cleans both
# owned temporary directories. All paths are contained in this disposable tree.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/go" <<'GO'
#!/usr/bin/env bash
if [ "$1" = env ]; then
  exec /usr/bin/go "$@"
fi
kill -TERM "$PPID"
sleep 0.1
exit 1
GO
chmod +x "$TMP/bin/go"
export PATH="$TMP/bin:$PATH"
interrupt_log="$TMP/interrupted.out"
setsid "$TMP/repo/bin/verify.sh" >"$interrupt_log" 2>&1 &
gate_pid=$!
rc=0
wait "$gate_pid" || rc=$?
[ "$rc" -ne 0 ] || { echo 'interrupted verifier exited successfully' >&2; exit 1; }
if compgen -G "$TMPDIR/herald-verify-*" >/dev/null || compgen -G "$TMPDIR/herald-verify-home-*" >/dev/null; then
  echo 'interrupted verifier leaked owned temp directories:' >&2
  find "$TMPDIR" -maxdepth 1 -type d >&2
  cat "$interrupt_log" >&2
  exit 1
fi

rc=0
HERALD_BIN="$TMP/missing-herald" bash "$TMP/repo/tests/notify-brief.test.sh" >"$TMP/invalid.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo "fixture accepted invalid HERALD_BIN" >&2; exit 1; }
grep -q 'HERALD_BIN is not executable' "$TMP/invalid.out"

rm -f "$TMP/repo/bin/herald"
PATH="$REAL_PATH"
export PATH
HERALD_VERIFY_ISOLATION_CHILD=1 bash "$TMP/repo/tests/notify-brief.test.sh" >"$TMP/standalone.out" 2>&1
grep -q 'notify brief: dead Kokoro exits 0' "$TMP/standalone.out"
[ ! -e "$TMP/repo/bin/herald" ] || { echo 'standalone fixture wrote deployment binary' >&2; exit 1; }

echo 'verify binary isolation: sentinel untouched, interrupted cleanup, invalid override and standalone build passed'
