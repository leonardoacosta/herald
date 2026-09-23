#!/usr/bin/env bash
# Hermetic regression checks for fail-soft project option parsing.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-notify-arguments.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state" "$TMP/config"
export HERALD="$REPO" HOME="$TMP/home" HERALD_STATE_DIR="$TMP/state" HERALD_CONFIG_DIR="$TMP/config"
export TRANSPORT_LOG="$TMP/transports.log"
REAL_TIMEOUT="$(command -v timeout)"
cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >> "$TRANSPORT_LOG"
exit 99
STUB
chmod +x "$TMP/bin/timeout"
export PATH="$TMP/bin:$PATH"

run_case() {
  local name="$1" script="$2" expected_rc="$3"
  shift 3
  local rc=0
  /usr/bin/timeout 2s bash "$script" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err" || rc=$?
  [ "$rc" -eq "$expected_rc" ] || {
    echo "$name: exit $rc, expected $expected_rc" >&2
    cat "$TMP/$name.err" >&2
    return 1
  }
}

for option in -p --project; do
  for tail in no-text after-text; do
    args=("$option")
    [ "$tail" = no-text ] || args=(text "$option")
    run_case "pipe-${option#-}-${tail}" "$REPO/bin/notify.sh" 0 "${args[@]}"
    grep -q 'requires a project argument' "$TMP/pipe-${option#-}-${tail}.err"

    for flags in '' '-e -u'; do
      name="plugin-${option#-}-${tail}-plain"
      strict_mode=()
      if [ -n "$flags" ]; then
        name="plugin-${option#-}-${tail}-strict"
        strict_mode=(-e -u)
      fi
      rc=0
      "$REAL_TIMEOUT" 2s bash "${strict_mode[@]}" -c 'source "$1"; say_notify "$@"; printf "rc=%s\n" "$?"' _ "$REPO/plugin/lib/notify.sh" "${args[@]}" >"$TMP/$name.out" 2>"$TMP/$name.err" || rc=$?
      [ "$rc" -eq 0 ] || { echo "$name: exit $rc" >&2; cat "$TMP/$name.err" >&2; exit 1; }
      grep -qx 'rc=0' "$TMP/$name.out"
      grep -q 'requires a project argument' "$TMP/$name.err"

      strict_args=("${args[@]}")
      [ -n "$flags" ] || continue
      rc=0
      "$REAL_TIMEOUT" 2s bash -e -u -c 'source "$1"; say_brief "$@"; printf "rc=%s\n" "$?"' _ "$REPO/plugin/lib/notify.sh" "${strict_args[@]}" >"$TMP/brief.out" 2>"$TMP/brief.err" || rc=$?
      [ "$rc" -eq 0 ] || { echo "say_brief: exit $rc" >&2; cat "$TMP/brief.err" >&2; exit 1; }
      grep -qx 'rc=0' "$TMP/brief.out"
    done
  done
done

[ ! -e "$TMP/state/notify.ndjson" ] || { echo 'invalid arguments wrote notification history' >&2; exit 1; }
[ ! -s "$TRANSPORT_LOG" ] || { echo 'invalid arguments invoked transport/timeout' >&2; cat "$TRANSPORT_LOG" >&2; exit 1; }

# Valid/empty project values and -- retain existing parsing and reach the timeout
# wrapper once. The stub records a transport attempt without invoking notify.
run_valid() {
  local name="$1"; shift
  : > "$TRANSPORT_LOG"
  "$REAL_TIMEOUT" 2s bash -c 'source "$1"; say_notify "$@"' _ "$REPO/plugin/lib/notify.sh" "$@" >/dev/null 2>&1 || true
  [ "$(wc -l < "$TRANSPORT_LOG")" -eq 1 ] || { echo "$name did not delegate once" >&2; cat "$TRANSPORT_LOG" >&2; exit 1; }
}
run_valid valid-project -p hs message
run_valid empty-project --project '' message
run_valid literal -- -p

# Direct pipe parser's -- path reaches its binary lookup, not option rejection.
# It still exits 0 and does not write history because this harness intentionally
# has no HERALD_BIN and uses a private state directory.
: > "$TRANSPORT_LOG"
# No options are parsed after --, so the message is treated as text.
"$REAL_TIMEOUT" 2s bash "$REPO/bin/notify.sh" -- -p >"$TMP/literal.out" 2>"$TMP/literal.err"

echo 'notify arguments: missing values fail soft; valid and literal arguments preserve delegation'
