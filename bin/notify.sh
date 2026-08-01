#!/usr/bin/env bash
# notify.sh — the notify pipe: text in, speech out on the playback host.
#
# Usage:
#   notify.sh [options] <text>...
#
# Options:
#   -p, --project CODE   projects.toml project code selecting a configured voice
#       --wait           block through playback (evidence capture); default is
#                        to return as soon as the audio bytes land
#   -h, --help           this text
#
# ALWAYS EXITS 0. This matches nx_send's fail-soft contract, which the cc
# cutover depends on: 25 shell call sites treat a notification as decoration,
# and none of them handle an error. A failure here is recorded in the notify
# history and reported on stderr, never propagated to the caller.
#
# Delivery is REMOTE-ONLY (Leo, 2026-07-25). The homelab synthesizes and the
# playback host plays; there is no local-playback path and no --local flag.
#
# Split of responsibilities: this script owns argument handling and the ssh
# transport; `herald notify` owns voice resolution, synthesis, and the
# history append (see pkg/notify/cli.go for why the pipe is split rather than
# living wholly in bash or wholly in Go).
set -uo pipefail
cd "$(dirname "$0")" || exit 0
# shellcheck disable=SC1091
source ./lib.sh

PROJECT=""
WAIT=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--project) PROJECT="${2:-}"; shift 2 ;;
    --wait) WAIT=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; ARGS+=("$@"); break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
TEXT="${ARGS[*]:-}"

warn() { echo "notify: $*" >&2; }

# The Go binary normally owns every history write. If that binary itself is
# unavailable, preserve the stronger public invariant — one attempt, one row —
# with a narrow emergency append. This is history-only, never a second speech
# path. jq preserves the attempted fields when available; the dependency-free
# fallback deliberately omits them rather than risk malformed JSON.
record_unavailable_binary() {
  local dir history ts line
  dir="$(herald_state_dir)"
  history="$dir/notify.ndjson"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  umask 077
  mkdir -p "$dir" 2>/dev/null || { warn "could not create history directory $dir"; return 0; }
  chmod 700 "$dir" 2>/dev/null || true
  if command -v jq >/dev/null 2>&1; then
    line="$(jq -cn --arg ts "$ts" --arg project "$PROJECT" --arg text "$TEXT" \
      '{ts:$ts, project:$project, text:$text, voice:"unknown", outcome:"synth_failed", reason:"herald binary unavailable"}' \
      2>/dev/null || true)"
  fi
  [ -n "${line:-}" ] || line="{\"ts\":\"$ts\",\"project\":\"\",\"text\":\"\",\"voice\":\"unknown\",\"outcome\":\"synth_failed\",\"reason\":\"herald binary unavailable; attempted fields omitted\"}"
  printf '%s\n' "$line" >> "$history" 2>/dev/null || warn "could not append the history record (synth_failed)"
}

if [ -z "${TEXT// /}" ]; then
  warn "nothing to say (no text argument)"
  exit 0
fi

# Configuration, one precedence rule for all four (lib.sh's herald_config):
# environment override, then $CONFIG_DIR/config, then the default.
#
# The kokoro default is loopback because synthesis and the pipe share the
# execution host — the compose module's tailnet bind exists for other clients,
# not for this one. This is also the ONLY place a kokoro address is written
# down: pkg/notify deliberately carries no default (see notify.BaseURLEnv).
BASE_URL="$(herald_config NOTIFY_KOKORO_BASE_URL HERALD_KOKORO_BASE_URL http://127.0.0.1:8880 HERDR_KOKORO_BASE_URL)"
PLAYBACK_HOST="$(herald_config NOTIFY_PLAYBACK_HOST HERALD_NOTIFY_PLAYBACK_HOST mac HERDR_NOTIFY_PLAYBACK_HOST)"
PLAYBACK_TIMEOUT="$(herald_config NOTIFY_PLAYBACK_TIMEOUT HERALD_NOTIFY_PLAYBACK_TIMEOUT 10 HERDR_NOTIFY_PLAYBACK_TIMEOUT)"
SYNTH_TIMEOUT="$(herald_config NOTIFY_SYNTH_TIMEOUT HERALD_NOTIFY_SYNTH_TIMEOUT 30 HERDR_NOTIFY_SYNTH_TIMEOUT)"
export HERALD_KOKORO_BASE_URL="$BASE_URL"

BIN="$(herald_bin)" || {
  record_unavailable_binary
  warn "herald binary not found (build it: go build -o bin/herald ./cmd/herald)"
  exit 0
}

record() {
  local outcome="$1" reason="${2:-}"
  local -a record_args=(notify record --project "$PROJECT" --text "$TEXT" --outcome "$outcome" --reason "$reason")
  if [ -n "${VOICE:-}" ]; then
    record_args+=(--voice "$VOICE" --speed "${SPEED:-0}")
  fi
  "$BIN" "${record_args[@]}" 2>/dev/null ||
    warn "could not append the history record ($outcome)"
}

# Mute is shared Herald state, so every harness and caller observes the same
# decision. The file contains an epoch-second expiry. Invalid and expired files
# are stale state: clean them and continue through the normal speech path.
MUTE_FILE="$(herald_state_dir)/mute"
if [ -f "$MUTE_FILE" ]; then
  IFS= read -r MUTE_UNTIL < "$MUTE_FILE" || true
  case "${MUTE_UNTIL:-}" in
    ''|*[!0-9]*) MUTE_UNTIL=0 ;;
  esac
  NOW="$(date +%s 2>/dev/null || printf '0')"
  if [ "$MUTE_UNTIL" -gt "$NOW" ] 2>/dev/null; then
    record muted "muted until epoch $MUTE_UNTIL"
    exit 0
  fi
  rm -f -- "$MUTE_FILE" 2>/dev/null || true
fi

# Local audio scratch. Guarded the same way the remote copy is: a caller killed
# mid-flight must not leave notification audio behind.
AUDIO="$(mktemp -t herald-notify.XXXXXX)" || { warn "could not create a temp file"; exit 0; }
trap 'rm -f "$AUDIO"' EXIT INT TERM

# Synthesis. stdout is the resolved voice (printed even on failure, so the
# history record can carry the voice that was going to be used); stderr is the
# reason, which becomes the record's reason verbatim.
SYNTH_ERR="$(mktemp -t herald-notify-err.XXXXXX)" || { warn "could not create a temp file"; exit 0; }
SPEED_META="$(mktemp -t herald-notify-speed.XXXXXX)" || { warn "could not create a temp file"; exit 0; }
trap 'rm -f "$AUDIO" "$SYNTH_ERR" "$SPEED_META"' EXIT INT TERM

VOICE="$("$BIN" notify synth \
  --project "$PROJECT" --text "$TEXT" --out "$AUDIO" --speed-out "$SPEED_META" --timeout "$SYNTH_TIMEOUT" \
  2>"$SYNTH_ERR")"
SYNTH_RC=$?
VOICE="${VOICE:-unknown}"
SPEED="$(tr -d '[:space:]' < "$SPEED_META" 2>/dev/null || true)"
SPEED="${SPEED:-0}"

if [ "$SYNTH_RC" -ne 0 ]; then
  REASON="$(tr '\n' ' ' < "$SYNTH_ERR")"
  record synth_failed "$REASON"
  warn "synthesis failed: $REASON"
  exit 0
fi

BYTES="$(wc -c < "$AUDIO" | tr -d ' ')"

# ── Delivery ────────────────────────────────────────────────────────────────
# Four constraints, each measured on 2026-07-25 and each guarding a failure the
# obvious implementation walks straight into (tasks.md 2.3):
#
# 1. timeout(1) wraps the ssh call. ConnectTimeout does NOT bound wall clock
#    here — the mesh's global `ConnectionAttempts 2` turned ConnectTimeout=3
#    into 7009ms elapsed against an offline node. The external timeout is the
#    only thing that makes "a sleeping playback host never holds the caller
#    open" true, and rc 124 is what distinguishes that case in the history.
#
# 2. NO `ssh -n`. -n redirects stdin from /dev/null, which silently discards
#    the piped audio: exit 0, no sound, no error. The precondition probes
#    elsewhere in this proposal correctly use -n because they pipe nothing;
#    copying that flag onto the delivery call is the footgun.
#
# 3. Ship to a remote file and play from it. afplay has no stdin mode
#    (`afplay -` -> "unknown argument: -"; `afplay /dev/stdin` -> AudioFileOpen
#    failed). One ssh round trip does `cat > "$f"` — no scp, no second
#    connection. The file needs no .mp3 extension: afplay sniffs content
#    (verified against an extensionless file holding kokoro's output).
#
# 4. A trap guards the remote temp file so a timeout-killed ssh cannot leak
#    audio into the Mac's /tmp. The trap is cleared only AFTER the bytes land
#    and the file is renamed into the spool — exactly the window a kill can
#    interrupt. The `</dev/null` on the drainer matters: a backgrounded process
#    still holding the ssh stdin channel keeps the connection open and defeats
#    the point of detaching.
#
# ── Spooling (serial-playback) ──────────────────────────────────────────────
# The obvious form — background `afplay` and return — mixes concurrent
# notifications into unintelligible overlap, because CoreAudio is happy to play
# two streams at once and nothing here took a turn. Reproduced 2026-08-01: two
# calls 1s apart left two afplay processes running together.
#
# So delivery enqueues instead of playing. Each call writes its audio into a
# spool and spawns a drainer CANDIDATE; exactly one candidate wins an atomic
# mkdir lock and plays clips oldest-first, back to back, until the spool empties.
# A clip arriving mid-playback is simply the next file the loop picks up, so the
# stream continues into it rather than over it.
#
# Four things this shape gets right, each guarding a way the naive version breaks:
#
# a. The clip is written under a dot-prefixed name and RENAMED into `clip.*`
#    only once complete. A drainer scanning mid-write would otherwise play a
#    truncated file.
# b. The claim happens INSIDE the backgrounded `sh -c`, not in this ssh session
#    shell. `$$` does not change in a subshell, so a lock stamped with the ssh
#    shell's pid would name a process that exits immediately and look stale to
#    every later caller. `sh -c` gets a real pid of its own.
# c. A stale lock is broken by RENAMING it aside, not by `rm -rf`. Two callers
#    both finding a dead owner would otherwise both delete and both recreate,
#    electing two drainers — the exact overlap this replaces. Only one `mv` can
#    win, because the source stops existing.
# d. On finding the spool empty the drainer releases the lock and RE-CHECKS. A
#    clip landing in that window belongs to a candidate that already failed to
#    claim and exited, so without the re-check it would sit unplayed until the
#    next notification.
#
# Ordering is by mtime (`ls -tr`), not by name: macOS `date` has no sub-second
# format, so two clips arriving in the same second cannot be ordered by a
# timestamp in the filename.
#
# The drainer plays a BATCH per pass — every clip currently spooled, cat'd into
# one file and handed to a single afplay — rather than one afplay per clip.
# Measured 2026-08-01 on the playback host: afplay costs ~1.2s of process start
# and audio-device open on top of the audio itself (1.824s of audio took 2.7-3.1s
# of wall clock), which is an audible dead pause between clips and the gap Leo
# reported. Concatenating is safe here because every clip is Kokoro mp3 from the
# same service: mp3 frames concatenate, and afinfo confirms the joined duration
# is the sum of its parts (2.664 + 2.712 -> 5.379s).
#
# The tradeoff this accepts: one corrupt clip now costs its whole batch rather
# than only itself. Synthesis failures never reach the spool (bin/notify.sh
# records synth_failed and returns long before delivery), so the realistic cause
# is a truncated transfer — which the .incoming rename already prevents.
#
# Silence is the worse failure. Every ambiguous path here resolves toward
# playing: a candidate that cannot claim exits quietly rather than blocking, and
# a drainer that dies leaves a lock the next caller breaks.
read -r -d '' REMOTE_SPOOL <<'REMOTE' || true
SPOOL=/tmp/herald-spool
umask 077
mkdir -p "$SPOOL" || exit 1

tmp=$(mktemp "$SPOOL/.incoming.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT INT TERM
cat > "$tmp"
clip="$SPOOL/clip.${tmp##*.}"
mv "$tmp" "$clip" || exit 1
trap - EXIT INT TERM

# Nudge a resident player, if one is running. This is the only thing delivery
# knows about it: a byte on a fifo, replacing a poll that measured ~500ms of
# coalesced sleep before the clip was noticed. Guarded on a live pidfile because
# ONLY the resident player publishes one — the fallback drainer must never be
# written to, and a write to a fifo whose reader has died would block. The
# background-and-forget keeps even that impossible case off the caller's clock.
player_pid=$(cat "$SPOOL/.player.pid" 2>/dev/null)
if [ -n "$player_pid" ] && kill -0 "$player_pid" 2>/dev/null && [ -p "$SPOOL/.wake" ]; then
  { printf 'x' > "$SPOOL/.wake" 2>/dev/null & } 2>/dev/null
fi

nohup sh -c '
SPOOL=/tmp/herald-spool
LOCK="$SPOOL/drainer.lock"
HELD=0
cleanup() { [ "$HELD" = 1 ] && rm -rf "$LOCK"; return 0; }
claim() {
  if mkdir "$LOCK" 2>/dev/null; then printf "%s\n" "$$" > "$LOCK/pid"; HELD=1; return 0; fi
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then return 1; fi
  mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null || return 1
  rm -rf "$LOCK.stale.$$"
  if mkdir "$LOCK" 2>/dev/null; then printf "%s\n" "$$" > "$LOCK/pid"; HELD=1; return 0; fi
  return 1
}
trap "" HUP
trap cleanup EXIT INT TERM
claim || exit 0
while :; do
  while :; do
    batch=$(ls -tr "$SPOOL"/clip.* 2>/dev/null)
    [ -n "$batch" ] || break
    joined="$SPOOL/.playing.$$"
    cat $batch > "$joined" 2>/dev/null
    afplay "$joined" >/dev/null 2>&1
    rm -f "$joined" $batch
  done
  HELD=0
  rm -rf "$LOCK"
  ls "$SPOOL"/clip.* >/dev/null 2>&1 || exit 0
  claim || exit 0
done
' </dev/null >/dev/null 2>&1 &

if [ "${HERALD_WAIT:-0}" = "1" ]; then
  while [ -e "$clip" ]; do sleep 0.2; done
fi
REMOTE

# --wait blocks until this call's own clip has been played, which now means
# waiting through anything already queued ahead of it. It exists for evidence
# capture, where an empty spool is the normal case; PLAYBACK_TIMEOUT still bounds
# it, so a --wait behind a long queue records transport_timeout rather than hanging.
REMOTE_CMD="$(printf 'HERALD_WAIT=%s\n%s' "$WAIT" "$REMOTE_SPOOL")"

SSH_ERR="$(mktemp -t herald-notify-ssh.XXXXXX)" || { warn "could not create a temp file"; exit 0; }
trap 'rm -f "$AUDIO" "$SYNTH_ERR" "$SPEED_META" "$SSH_ERR"' EXIT INT TERM

timeout "$PLAYBACK_TIMEOUT" \
  ssh -o BatchMode=yes "$PLAYBACK_HOST" "$REMOTE_CMD" \
  < "$AUDIO" >/dev/null 2>"$SSH_ERR"
SSH_RC=$?

case "$SSH_RC" in
  0)
    record delivered ""
    echo "notify: delivered ${BYTES} bytes as $VOICE to $PLAYBACK_HOST"
    ;;
  124)
    # timeout(1)'s own exit code — the playback host was asleep or off the
    # tailnet. Its own outcome, because that is the state an operator wants to
    # see on the board rather than a generic transport failure.
    REASON="ssh exited 124 after ${PLAYBACK_TIMEOUT}s (playback host $PLAYBACK_HOST asleep or unreachable?)"
    record transport_timeout "$REASON"
    warn "$REASON"
    ;;
  *)
    REASON="ssh to $PLAYBACK_HOST exited $SSH_RC: $(tr '\n' ' ' < "$SSH_ERR")"
    record transport_failed "$REASON"
    warn "$REASON"
    ;;
esac

exit 0
