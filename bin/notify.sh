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
  "$BIN" notify record \
    --project "$PROJECT" --text "$TEXT" --voice "$VOICE" \
    --speed "${SPEED:-0}" --outcome "$outcome" --reason "$reason" 2>/dev/null ||
    warn "could not append the history record ($outcome)"
}

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
# 3. Ship to a remote mktemp and play from the file. afplay has no stdin mode
#    (`afplay -` -> "unknown argument: -"; `afplay /dev/stdin` -> AudioFileOpen
#    failed). One ssh round trip does `cat > "$f"; afplay "$f"` — no scp, no
#    second connection. The temp file needs no .mp3 extension: afplay sniffs
#    content (verified against an extensionless file holding kokoro's output).
#
# 4. A trap guards the remote temp file so a timeout-killed ssh cannot leak
#    audio into the Mac's /tmp.
#
# The detached form clears that trap only AFTER handing the file to a
# backgrounded player that owns cleanup itself — the trap covers exactly the
# window between mktemp and the bytes landing, which is the window a kill can
# interrupt. Its `</dev/null` matters: a backgrounded process still holding the
# ssh stdin channel keeps the connection open and defeats the point of
# detaching.
read -r -d '' REMOTE_WAIT <<'REMOTE' || true
f=$(mktemp /tmp/herald-notify.XXXXXX)
trap 'rm -f "$f"' EXIT INT TERM
cat > "$f"
afplay "$f"
REMOTE

read -r -d '' REMOTE_DETACH <<'REMOTE' || true
f=$(mktemp /tmp/herald-notify.XXXXXX)
trap 'rm -f "$f"' EXIT INT TERM
cat > "$f"
nohup sh -c 'afplay "$0"; rm -f "$0"' "$f" </dev/null >/dev/null 2>&1 &
trap - EXIT INT TERM
REMOTE

if [ "$WAIT" -eq 1 ]; then REMOTE_CMD="$REMOTE_WAIT"; else REMOTE_CMD="$REMOTE_DETACH"; fi

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
