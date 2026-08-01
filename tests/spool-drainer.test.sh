#!/usr/bin/env bash
# serial-playback tasks 2.2 / 2.3 / 3.1 — the spool + drainer algorithm.
#
# Hermetic: the remote script is READ from pkg/notify/remote_spool.sh — the one
# copy that bin/notify.sh reads and pkg/notify go:embeds — rather than restated
# here, its spool path is repointed at a temp dir, and a fake afplay stands in
# for the real one. No ssh, no Mac, no audio.
#
# Overlap is detected structurally, not by polling: the fake player brackets
# each clip with START/END lines, so two players running at once necessarily
# produce two STARTs with no END between them.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-spool.XXXXXX)"
# Cleanup is a plain rm. An earlier version also ran `pkill -f "$TMP/spool"` to
# sweep stray drainers; that pattern matched this shell's own process and killed
# the test at the moment of exit, so a passing run reported failure. Nothing
# needs sweeping: drain_settle already blocks until the lock is released, which
# is precisely the point at which every drainer has exited.
# shellcheck disable=SC2154  # rc is assigned in this same trap string
trap 'rc=$?; rm -rf "$TMP"; exit $rc' EXIT INT TERM

SPOOL="$TMP/spool"
LOG="$TMP/play.log"
: > "$LOG"

# Read the canonical remote spool script and repoint it at the test spool.
# pkg/notify/remote_spool.sh is the ONE copy: bin/notify.sh reads it and
# pkg/notify go:embeds it, so this test exercises exactly what ships.
sed "s#/tmp/herald-spool#$SPOOL#g" "$REPO/pkg/notify/remote_spool.sh" > "$TMP/remote.sh"
grep -q 'afplay' "$TMP/remote.sh" || { echo "extraction produced no drainer" >&2; exit 1; }

# Fake afplay: brackets each PLAYBACK so overlap is visible in the log, and is
# slow enough that a second enqueue lands mid-playback.
#
# The drainer batches — it cat's every spooled clip into one file per pass — so
# one playback may carry several clips and "number of afplay calls" is NOT the
# number of clips. Assertions below count clip payloads inside the log, never
# START lines.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/afplay" <<'FAKE'
#!/usr/bin/env bash
printf 'START %s\n' "$(cat "$1")" >> "$PLAY_LOG"
sleep 0.4
printf 'END %s\n' "$(cat "$1")" >> "$PLAY_LOG"
FAKE
chmod +x "$TMP/bin/afplay"
export PATH="$TMP/bin:$PATH" PLAY_LOG="$LOG"

enqueue() { printf '%s' "$1" | sh "$TMP/remote.sh"; }

drain_settle() {
  for _ in $(seq 1 100); do
    [ -z "$(ls "$SPOOL"/clip.* 2>/dev/null)" ] && [ ! -d "$SPOOL/drainer.lock" ] && return 0
    sleep 0.2
  done
  echo "spool never drained: $(ls "$SPOOL" 2>/dev/null)" >&2
  return 1
}

# Wait for N clips to finish playing. drain_settle alone is not enough: an
# implementation that ignores the spool entirely drains it "instantly" (there is
# nothing in it), so the log would be inspected mid-write and a burst of
# simultaneous players could read as a clean run. Gate on observed completions.
# Count distinct clip payloads that have finished playing. Counts payloads, not
# afplay invocations, because a batch carries several clips through one call.
played_clips() { grep '^END' "$LOG" 2>/dev/null | grep -o 'clip-[0-9]*' | sort -u | wc -l | tr -d ' '; }

wait_for_clips() {
  want="$1"
  for _ in $(seq 1 100); do
    [ "$(played_clips)" -ge "$want" ] && return 0
    sleep 0.2
  done
  echo "only $(played_clips) of $want clips finished" >&2
  return 1
}

# Wait for N completed playbacks (afplay calls), for the cases that care about
# batching boundaries rather than clip payloads.
wait_for_playbacks() {
  want="$1"
  # `|| true`, never `|| echo 0`: grep -c already PRINTS 0 on no match and then
  # exits 1, so the fallback appended a second line and `[` got "0\n0".
  for _ in $(seq 1 100); do
    [ "$(grep -c '^END' "$LOG" 2>/dev/null || true)" -ge "$want" ] && return 0
    sleep 0.2
  done
  echo "only $(grep -c '^END' "$LOG" 2>/dev/null || true) of $want playbacks finished" >&2
  return 1
}

assert_no_overlap() {
  awk '
    /^START/ { if (playing) { print "OVERLAP at " $0; bad=1 } playing=1 }
    /^END/   { playing=0 }
    END { exit bad ? 1 : 0 }
  ' "$LOG" || { echo "two clips played at once:" >&2; cat "$LOG" >&2; exit 1; }
}

# ── 1. A burst of concurrent enqueues never double-plays, and loses nothing ──
for i in 1 2 3 4 5; do enqueue "clip-$i" & done
wait
wait_for_clips 5
drain_settle
assert_no_overlap
PLAYED=$(played_clips)
[ "$PLAYED" -eq 5 ] || { echo "played $PLAYED of 5 clips" >&2; cat "$LOG" >&2; exit 1; }

# Clips that were already queued go out in ONE playback. Guards the gap fix:
# afplay costs ~1.2s of device-open per call on the real host, so a regression
# to one call per clip is silent in every other assertion here but audible as a
# dead pause between every message.
PLAYBACKS=$(grep -c '^END' "$LOG" || true)
[ "$PLAYBACKS" -lt 5 ] || {
  echo "5 queued clips became $PLAYBACKS separate playbacks — batching regressed" >&2
  cat "$LOG" >&2; exit 1; }

# ── 2. A clip arriving mid-playback extends the stream (no second player) ────
: > "$LOG"
enqueue "clip-1"
sleep 0.15                    # clip-1 is mid-flight, so clip-2 cannot batch with it
enqueue "clip-2"
wait_for_clips 2
drain_settle
assert_no_overlap
# Two separate playbacks: the second arrived too late to join the first batch.
[ "$(grep -c '^END' "$LOG" || true)" -eq 2 ] || {
  echo "mid-playback arrival did not become its own playback" >&2; cat "$LOG" >&2; exit 1; }
# Arrival order is play order.
[ "$(grep '^START' "$LOG" | head -1)" = "START clip-1" ] || {
  echo "played out of arrival order:" >&2; cat "$LOG" >&2; exit 1; }

# ── 3. A dead drainer's lock never mutes the host ────────────────────────────
: > "$LOG"
mkdir -p "$SPOOL/drainer.lock"
# A pid that cannot be alive: claim() must break this lock, not defer to it.
printf '%s\n' 999999 > "$SPOOL/drainer.lock/pid"
enqueue "after-stale-lock"
wait_for_playbacks 1
drain_settle
[ "$(grep -c '^START' "$LOG" || true)" -eq 1 ] || {
  echo "a stale lock suppressed playback — silence is the worse failure" >&2
  cat "$LOG" >&2; exit 1; }

# ── 4. A LIVE owner is respected: no second drainer elected ──────────────────
: > "$LOG"
sleep 300 & LIVE=$!
mkdir -p "$SPOOL/drainer.lock"
printf '%s\n' "$LIVE" > "$SPOOL/drainer.lock/pid"
enqueue "queued-behind-live-owner"
sleep 0.6
STARTED=$(grep -c '^START' "$LOG" || true)
kill "$LIVE" 2>/dev/null || true
[ "$STARTED" -eq 0 ] || {
  echo "a second drainer was elected while one held the lock" >&2; exit 1; }
rm -rf "$SPOOL/drainer.lock"

echo "spool drainer: burst, mid-playback arrival, stale-lock recovery, and live-owner deference passed"
