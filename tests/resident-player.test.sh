#!/usr/bin/env bash
# warm-playback task 3.2 — the resident player and the fallback drainer must
# never both play.
#
# Hermetic: a fake mpg123 speaks just enough of the -R control protocol, a fake
# afplay stands in for the fallback, and both bracket their work in one log so
# overlap is structural rather than sampled. No audio, no ssh, no Mac.
#
# This is the guard that matters most. The two paths are deliberately different
# processes reaching the same spool, and the ONLY thing keeping them apart is the
# lock — which a bug already broke once during development (a restarted player's
# cleanup deleted its successor's lock, leaving the spool unowned).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-resident.XXXXXX)"
# shellcheck disable=SC2154  # rc is assigned in this same trap string
trap 'rc=$?; [ -n "${PLAYER_PID:-}" ] && kill -9 "$PLAYER_PID" 2>/dev/null; rm -rf "$TMP"; exit $rc' EXIT INT TERM

SPOOL="$TMP/spool"
LOG="$TMP/play.log"
mkdir -p "$TMP/bin" "$SPOOL"
: > "$LOG"

# Fake mpg123 in remote-control mode: consumes `load <file>` and `quit`, and
# brackets each track so a concurrent afplay is visible in the same log.
cat > "$TMP/bin/mpg123" <<'FAKE'
#!/usr/bin/env bash
# Ignore flags; read commands on stdin like mpg123 -R.
printf '@R FAKE\n'
while IFS= read -r line; do
  case "$line" in
    load\ *)
      f="${line#load }"
      printf 'START player %s\n' "$(basename "$f")" >> "$PLAY_LOG"
      sleep 0.4
      printf 'END player %s\n' "$(basename "$f")" >> "$PLAY_LOG"
      printf '@P 0\n'
      ;;
    quit) exit 0 ;;
  esac
done
FAKE

# Fake afplay: the fallback path.
cat > "$TMP/bin/afplay" <<'FAKE'
#!/usr/bin/env bash
printf 'START fallback %s\n' "$(basename "$1")" >> "$PLAY_LOG"
sleep 0.4
printf 'END fallback %s\n' "$(basename "$1")" >> "$PLAY_LOG"
FAKE
chmod +x "$TMP/bin/mpg123" "$TMP/bin/afplay"
export PATH="$TMP/bin:$PATH" PLAY_LOG="$LOG"

# The enqueue half of delivery, read from the canonical remote script both
# bin/notify.sh and pkg/notify use, so this test cannot drift from what runs.
sed "s#/tmp/herald-spool#$SPOOL#g" "$REPO/pkg/notify/remote_spool.sh" > "$TMP/enqueue.sh"
grep -q 'clip\.' "$TMP/enqueue.sh" || { echo "enqueue extraction failed" >&2; exit 1; }

enqueue() { printf '%s' "$1" | sh "$TMP/enqueue.sh"; }

assert_no_overlap() {
  awk '
    /^START/ { if (playing) { print "OVERLAP: " $0; bad=1 } playing=1 }
    /^END/   { playing=0 }
    END { exit bad ? 1 : 0 }
  ' "$LOG" || { echo "player and fallback played at once:" >&2; cat "$LOG" >&2; exit 1; }
}

wait_for() {
  local pattern="$1" n="$2"
  for _ in $(seq 1 100); do
    [ "$(grep -c "$pattern" "$LOG" 2>/dev/null || true)" -ge "$n" ] && return 0
    sleep 0.1
  done
  return 1
}

# ── 1. With a live player holding the lock, the fallback must not play ───────
HERALD_SPOOL="$SPOOL" HERALD_PLAYER_IDLE=3600 HERALD_PLAYER_SILENCE="$TMP/none.mp3" \
  bash "$REPO/bin/herald-player.sh" > "$TMP/player.log" 2>&1 &
PLAYER_PID=$!
for _ in $(seq 1 50); do [ -f "$SPOOL/.player.pid" ] && break; sleep 0.1; done
[ -f "$SPOOL/.player.pid" ] || { echo "player never published its pidfile" >&2; cat "$TMP/player.log" >&2; exit 1; }
[ "$(cat "$SPOOL/drainer.lock/pid")" = "$(cat "$SPOOL/.player.pid")" ] || {
  echo "player holds the pidfile but not the lock" >&2; exit 1; }

for i in 1 2 3; do enqueue "clip-$i"; done
wait_for '^END player' 3 || { echo "player did not play all clips" >&2; cat "$LOG" >&2; exit 1; }
assert_no_overlap
grep -q '^START fallback' "$LOG" && {
  echo "fallback played while the resident player held the lock" >&2; cat "$LOG" >&2; exit 1; }

# ── 2. Player dies -> the fallback takes over rather than going silent ───────
kill -9 "$PLAYER_PID" 2>/dev/null
# Reap it quietly; otherwise bash prints its own "Killed" job notice on the next
# prompt and a passing run looks like it crashed.
wait "$PLAYER_PID" 2>/dev/null || true
PLAYER_PID=""
sleep 0.5
[ -d "$SPOOL/drainer.lock" ] || { echo "expected the killed player to leave its lock behind" >&2; exit 1; }

: > "$LOG"
enqueue "after-death"
wait_for '^END fallback' 1 || {
  echo "a dead player silenced the spool — the fallback never ran" >&2
  cat "$LOG" >&2; exit 1; }
assert_no_overlap

echo "resident player: exclusive while alive, fallback takes over when dead"
