#!/usr/bin/env bash
# herald-player — resident spool player for the playback host.
#
# Installed onto the playback host (the Mac) by bin/player-sync.sh, never by
# hand, and supervised by a launchd user agent. It consumes the SAME spool
# bin/notify.sh already writes to; delivery does not know it exists.
#
# Why this exists (warm-playback proposal § Measured): spawning a player per
# clip costs 847-1309ms before a sound comes out, which is an audible pause
# before every notification. Most of that is the player process and its stream
# setup, not the audio device — a process merely HOLDING the device open only
# got it to ~850ms. A resident mpg123 in remote-control mode, already holding an
# open stream and simply told to load a file, reaches first sample in 33-44ms.
#
# ── Lock protocol ───────────────────────────────────────────────────────────
# This player claims bin/notify.sh's drainer lock and HOLDS IT for its whole
# lifetime, rather than per batch. That is what makes the fallback automatic and
# race-free: every enqueue still spawns a candidate drainer, every candidate
# fails to claim while this player lives and exits immediately, so there is
# exactly one playback path at a time. If this process dies, the lock it leaves
# names a dead pid, and the next candidate breaks it and drains with afplay
# exactly as before. Nothing needs to detect "is the daemon healthy" — a
# notification that finds no live player simply plays the old way.
#
# The lock is NOT the audio device. Releasing the device on idle (below) leaves
# the lock held, because this process is still the one that will play the next
# clip.
set -uo pipefail

SPOOL="${HERALD_SPOOL:-/tmp/herald-spool}"
LOCK="$SPOOL/drainer.lock"
FIFO="$SPOOL/.player.in"
OUT="$SPOOL/.player.out"
# Wake channel. Enqueue writes a byte here after a clip lands, so this process
# learns about it by BLOCKING rather than by polling. Polling was the last big
# term in the latency budget: a `sleep 0.05` detect loop measured ~500ms of
# real delay because the sleep is coalesced, which put total overhead at ~550ms
# even after the decoder itself was down to ~80ms. The fifo is opened read-write
# (fd 5) so it always has a reader — writers never block, and a read never hits
# EOF and spins.
WAKE="$SPOOL/.wake"
# Published so enqueue can tell a resident player (which listens on $WAKE) from
# a fallback drainer (which does not, and must never be signalled or written to).
PIDFILE="$SPOOL/.player.pid"
# Control channel is two fifos, and completion is read with a BLOCKING read
# rather than polled from a file. Polling is what launchd punishes: under the
# agent, `sleep 0.02` in the completion loop is coalesced into something far
# coarser and the same clip that takes 1905ms hand-run took 2350ms supervised —
# +445ms of pure detection lag, measured 2026-08-01. A blocking read on a fifo
# is not subject to timer coalescing.
# Seconds of silence before the audio device is released. Holding it forever is
# a real cost to everything else on the Mac (the device reads as in use), and
# the pause it saves only matters between notifications that are close together.
IDLE="${HERALD_PLAYER_IDLE:-900}"
# A single clip should never take this long; the cap keeps a wedged decoder from
# stalling the queue forever. A 150-word briefing is ~60s.
CLIP_CAP="${HERALD_PLAYER_CLIP_CAP:-300}"
# Output device buffer, in seconds. This single flag is what makes a resident
# decoder worth having: mpg123's default device buffer costs ~500ms per clip
# waiting to fill, which is most of the way back to spawning afplay. At 0.1s the
# same clip carries 73-94ms of overhead (measured 2026-08-01). Raise it if audio
# ever breaks up under load — a small device buffer trades dropout headroom for
# latency, and a dropout is worse than a pause.
DEVBUFFER="${HERALD_PLAYER_DEVBUFFER:-0.1}"
# Silence played between clips to keep the output stream ACTIVE. This is the
# single biggest win in the whole change and the one the proposal's premise
# missed: a decoder that is merely loaded, with the device idle between clips,
# costs 506-559ms per clip; the same decoder with silence playing costs 82-96ms
# (measured 2026-08-01, four runs each, both tight). The device powers down
# between notifications, and waking it is ~420ms.
#
# The file MUST be longer than IDLE, or silence ends first and the device powers
# down while this process still believes it is warm. player-sync.sh generates it
# at 1800s against a 900s default.
SILENCE="${HERALD_PLAYER_SILENCE:-$HOME/.local/share/herald/silence.mp3}"

log() { printf '%s herald-player: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Millisecond clock for latency accounting. Only called when HERALD_PLAYER_DEBUG
# is set: BSD date has no %N, so this costs a python3 fork (~30ms) and would
# otherwise be charged to the very latency it measures.
DEBUG="${HERALD_PLAYER_DEBUG:-0}"
ms() { [ "$DEBUG" = 1 ] && python3 -c 'import time;print(int(time.time()*1000))' || printf '0'; }
dbg() { [ "$DEBUG" = 1 ] && log "$*"; return 0; }

umask 077
mkdir -p "$SPOOL" || { log "cannot create spool $SPOOL"; exit 1; }

command -v mpg123 >/dev/null 2>&1 || {
  log "mpg123 not found — leaving the spool to the fallback drainer"
  exit 1
}

MPG_PID=""
HELD=0

# ── Lock ────────────────────────────────────────────────────────────────────
# Same protocol as the drainer in bin/notify.sh: atomic mkdir, pid inside, and a
# stale lock broken by renaming it aside so two claimants cannot both win.
claim() {
  if mkdir "$LOCK" 2>/dev/null; then printf '%s\n' "$$" > "$LOCK/pid"; HELD=1; return 0; fi
  local owner
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then return 1; fi
  mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null || return 1
  rm -rf "$LOCK.stale.$$"
  if mkdir "$LOCK" 2>/dev/null; then printf '%s\n' "$$" > "$LOCK/pid"; HELD=1; return 0; fi
  return 1
}

# ── mpg123 in remote-control mode ───────────────────────────────────────────
# `-R` reads commands on stdin and reports state on stdout, keeping the audio
# device open between tracks — the whole point of this process.
start_player() {
  [ -n "$MPG_PID" ] && kill -0 "$MPG_PID" 2>/dev/null && return 0
  rm -f "$FIFO" "$OUT"
  mkfifo "$FIFO" "$OUT" 2>/dev/null || { log "cannot create control fifos"; return 1; }
  mpg123 -R --devbuffer "$DEVBUFFER" < "$FIFO" > "$OUT" 2>/dev/null &
  MPG_PID=$!
  # Rendezvous order matters: mpg123 blocks opening its stdin fifo until fd 3 is
  # opened for write, then blocks opening its stdout fifo until fd 4 is opened
  # for read. Opening them in this order is what keeps both sides from deadlocking.
  exec 3> "$FIFO"
  exec 4< "$OUT"
  sleep 0.3
  kill -0 "$MPG_PID" 2>/dev/null || { log "mpg123 failed to start"; MPG_PID=""; return 1; }
  # Stop per-frame "@F" chatter: one line per decoded frame is thousands of
  # reads per clip for no information. State lines (@P/@S/@E) still arrive,
  # which is all play() consumes.
  printf 'silence\n' >&3 2>/dev/null || true
  return 0
}

stop_player() {
  [ -n "$MPG_PID" ] || return 0
  printf 'quit\n' >&3 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  exec 4<&- 2>/dev/null || true
  # Give it a moment to close the device cleanly before insisting.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$MPG_PID" 2>/dev/null || break
    sleep 0.1
  done
  kill "$MPG_PID" 2>/dev/null || true
  MPG_PID=""
  rm -f "$FIFO" "$OUT"
}

# Play one file through the resident stream. Returns non-zero if the decoder
# never reported completion, so the caller can restart it rather than wedge.
#
# Completion is detected by COUNTING "@P 0" (stopped) lines, not by truncating
# the transcript and looking for one. Truncation does not work here: mpg123 holds
# $OUT open at its own write offset, so `: > $OUT` leaves a sparse hole and every
# later grep scans a file that only grows. Measured 2026-08-01 — per-clip
# overhead climbed 458 -> 579 -> 765ms across three consecutive clips, against
# 81-93ms for the same decoder driven directly.
# Keep the output stream active so the device cannot power down between clips.
# Loading a clip over playing silence is safe: mpg123 emits no "@P 0" for the
# interrupted track, so completion detection still sees exactly one (verified
# against a captured transcript, 2026-08-01).
warm() {
  [ -n "$MPG_PID" ] || return 0
  [ -r "$SILENCE" ] || return 0
  printf 'load %s\n' "$SILENCE" >&3 2>/dev/null || true
}

play() {
  local file="$1" line waited=0
  # Drain anything buffered before issuing the load. Silence reaching its own
  # end emits a "@P 0" that nobody consumed; left in the fifo it would be read
  # as THIS clip finishing, and the clip would be deleted while still playing.
  while IFS= read -r -t 0.01 line <&4; do :; done
  printf 'load %s\n' "$file" >&3 2>/dev/null || return 1
  while :; do
    # -t 1 bounds the wait so a wedged decoder cannot stall the queue forever,
    # while the read itself still blocks (and so returns the instant mpg123
    # speaks) rather than sampling on a coalesced timer.
    if IFS= read -r -t 1 line <&4; then
      case "$line" in
        '@P 0'*) return 0 ;;   # stopped: this clip finished
        '@E '*)  log "decoder error: $line"; return 1 ;;
      esac
      continue
    fi
    # Timed out (or EOF): make sure the decoder is still there before waiting more.
    kill -0 "$MPG_PID" 2>/dev/null || return 1
    waited=$((waited + 1))
    [ "$waited" -gt "$CLIP_CAP" ] && { log "clip exceeded ${CLIP_CAP}s cap"; return 1; }
  done
}

# Release the lock only if we still OWN it. Checking $HELD alone is not enough:
# `launchctl kickstart -k` starts the replacement before the outgoing process
# has finished exiting, so a bare `rm -rf` here deletes the SUCCESSOR's lock.
# Observed live 2026-08-01 — the new player logged "holding the spool lock"
# while no lock existed on disk, which would have let a fallback drainer claim
# it and play concurrently with the resident player: the overlap defect
# serial-playback exists to prevent, reintroduced by its own successor.
cleanup() {
  stop_player
  # Retract the wake channel BEFORE releasing the lock: an enqueue that still
  # sees a live pidfile would otherwise write to a fifo with no reader.
  [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"
  exec 5<&- 2>/dev/null || true
  rm -f "$WAKE"
  if [ "$HELD" = 1 ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK"
  fi
  return 0
}

# The lock must be held for as long as this process intends to play. Anything
# that removes it out from under us (a predecessor's exit, an operator clearing
# the spool) has to be noticed, or two playback paths run at once.
own_lock() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; }
trap cleanup EXIT INT TERM

# The player is the intended lock owner, so it waits for the lock rather than
# giving up: a fallback drainer mid-batch will release within one batch.
while ! claim; do sleep 0.5; done
log "holding the spool lock (pid $$), idle release after ${IDLE}s"

# Open the wake channel only once the lock is ours, so a waiting claimant never
# advertises itself as the player.
rm -f "$WAKE"
mkfifo "$WAKE" 2>/dev/null || log "no wake fifo — falling back to polling"
exec 5<> "$WAKE" 2>/dev/null || true
printf '%s\n' "$$" > "$PIDFILE"

LAST_ACTIVITY=$(date +%s)
while :; do
  # Re-assert ownership before touching the spool. Cheap on tmpfs, and it is the
  # only thing standing between a lost lock and two players.
  if ! own_lock; then
    HELD=0
    stop_player
    log "lost the spool lock — reclaiming before playing anything"
    while ! claim; do sleep 0.5; done
    log "re-claimed the spool lock (pid $$)"
  fi

  # shellcheck disable=SC2012  # controlled filenames; -tr is mtime order
  batch=$(ls -tr "$SPOOL"/clip.* 2>/dev/null)
  if [ -n "$batch" ]; then
    t_detect=$(ms)
    start_player || { sleep 1; continue; }
    t_ready=$(ms)
    for clip in $batch; do
      [ -e "$clip" ] || continue
      t0=$(ms)
      play "$clip" || { log "playback failed; restarting the decoder"; stop_player; }
      t1=$(ms)
      rm -f "$clip"
      dbg "clip: start_player $((t_ready - t_detect))ms, play $((t1 - t0))ms"
    done
    # Resume silence immediately so the device stays awake for whatever lands next.
    warm
    LAST_ACTIVITY=$(date +%s)
  else
    if [ -n "$MPG_PID" ] && [ $(( $(date +%s) - LAST_ACTIVITY )) -ge "$IDLE" ]; then
      log "idle ${IDLE}s — releasing the audio device"
      stop_player
    fi
    # Block until enqueue nudges the wake channel. The timeout is a safety net,
    # not the mechanism: it bounds how long an idle-release check waits and
    # covers the case where the fifo could not be created, so a missed nudge
    # costs half a second rather than silence.
    IFS= read -r -t 0.5 _ <&5 2>/dev/null || true
  fi
done
