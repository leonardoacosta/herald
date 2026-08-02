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
# This script is a CLIENT of herald's resident service (`herald notify
# serve`, tasks 1.4/1.5) first: it posts to the service and, if the service
# is reachable, returns as soon as the service responds — the service owns
# the history record for that call. Everything below the "## Service
# attempt" block only runs when the service could not be reached at all, or
# when --wait bypassed it outright. See that block for exactly what
# "reachable" means and why it is not simply "curl exited 0".
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

# ── Divergence bypass ─────────────────────────────────────────────────────────
# Amendment 2026-08-01 (proposal.md "one config instance, not two resolutions",
# closing paragraph): with $HERALD_CONFIG_DIR/config as the ONE shared file
# describing the deployed pipeline (tasks 4.1/4.2 — systemd's EnvironmentFile=
# and this script's own `source` both read it), a caller whose resolved config
# disagrees with that file is by construction describing a DIFFERENT herald
# than the one the service on this host is serving: state dir is where its
# history/mute state lives, Kokoro URL is which synthesis engine answers it.
# Handing such a caller's notification to that service would make the service
# synthesize with the wrong Kokoro or record the outcome into a state dir the
# caller never reads — not a timing race like the ones "## Service attempt"
# below guards against, but a wrong-recipient bug no reachability check can
# see, because the connection itself succeeds. So this caller takes the same
# carve-out --wait already uses: skip the service, run the local path.
#
# This is a NEW, EARLIER condition than "## Service attempt" below, not a
# change to its reachable/unreachable logic — it decides whether to attempt
# the service AT ALL, before that block ever asks whether the attempt landed.
#
# Applies ONLY when SERVICE_URL is still the well-known default. A caller
# that has explicitly pointed HERALD_NOTIFY_SERVICE_URL somewhere else has
# already made an informed choice about which pipeline it is calling —
# tests/notify-service.test.sh does exactly this, standing up its own
# ephemeral `herald notify serve` with a state dir and Kokoro stub that have
# nothing to do with $HERALD_CONFIG_DIR/config, and pointing
# HERALD_NOTIFY_SERVICE_URL at it on purpose. Comparing THAT caller's config
# against the deployed file would reject a deliberate multi-instance caller
# as if it were the confused one. The confusion this check exists to catch is
# narrower: "I never thought about the service at all, I just hit the default
# URL, and my config happens to describe something else" — exactly
# tests/notify-brief.test.sh, the regression that motivated this task.
#
# Deliberately excluded: HERALD_NOTIFY_PLAYBACK_HOST. It names where audio is
# DELIVERED, not which service/state/synthesis instance answers the request —
# a caller can legitimately want its own playback target without describing a
# different pipeline. (If it diverges, the service's async worker still plays
# to ITS OWN configured host regardless of what the caller sent — true today,
# independent of this task, and not something this check is positioned to fix
# without a request-scoped playback override, which is out of scope here.)
#
# Deliberately no second `source`: bin/lib.sh already applied the file to
# THIS process with env-beats-file precedence (task 4.1), so RESOLVED_STATE_DIR
# and BASE_URL below already carry that resolution. deployed_config_value
# parses the file a second time, independently, so the comparison is the
# caller's RESOLVED value against the file's DECLARED value — sourcing again
# here would just reassign the same variables, telling us nothing.
#
# Absent file (a box that never ran bin/service-sync.sh) means no declared
# deployment to diverge from, so the comparison falls back to the documented
# defaults ($HOME/.local/state/herald, http://127.0.0.1:8880 — bin/lib.sh line
# 47 and this script's own BASE_URL default above) instead of skipping the
# check outright. That keeps a fresh machine self-consistent rather than
# exempting every call from the guard just because service-sync.sh never ran.
SERVICE_URL_DEFAULT="http://127.0.0.1:8881"

# deployed_config_value <KEY> <DEFAULT>
# One KEY=value line from the shared config file, read without sourcing it —
# grep+cut is sufficient because bin/lib.sh's header constrains the format to
# plain KEY=value with no shell.
deployed_config_value() {
  local key="$1" default="$2" file="$HERALD_CONFIG_DIR/config" line
  if [ -r "$file" ]; then
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1)"
    [ -n "$line" ] && { printf '%s\n' "${line#*=}"; return 0; }
  fi
  printf '%s\n' "$default"
}

RESOLVED_STATE_DIR="$(herald_state_dir)"
DEPLOYED_STATE_DIR="$(deployed_config_value HERALD_STATE_DIR "$HOME/.local/state/herald")"
DEPLOYED_KOKORO_URL="$(deployed_config_value HERALD_KOKORO_BASE_URL "http://127.0.0.1:8880")"

# Loopback default: like BASE_URL above, notify.sh and the service normally
# colocate on the execution host — the tailnet bind exists for OTHER callers
# (pi), not for this one. herald_config gives this the same env/config/default
# precedence as every other setting here (AGENTS.md "No hardcoded host
# addresses"). Resolved here (rather than inside "## Service attempt" below)
# so the divergence gate above can compare against it before deciding whether
# to enter that block at all.
SERVICE_URL="$(herald_config NOTIFY_SERVICE_URL HERALD_NOTIFY_SERVICE_URL "$SERVICE_URL_DEFAULT")"
SERVICE_URL="${SERVICE_URL%/}"
SERVICE_CONNECT_TIMEOUT="$(herald_config NOTIFY_SERVICE_CONNECT_TIMEOUT HERALD_NOTIFY_SERVICE_CONNECT_TIMEOUT 2)"
SERVICE_MAX_TIME="$(herald_config NOTIFY_SERVICE_TIMEOUT HERALD_NOTIFY_SERVICE_TIMEOUT 5)"

PIPELINE_DIVERGES=0
if [ "$SERVICE_URL" = "$SERVICE_URL_DEFAULT" ] && \
   { [ "$RESOLVED_STATE_DIR" != "$DEPLOYED_STATE_DIR" ] || [ "$BASE_URL" != "$DEPLOYED_KOKORO_URL" ]; }; then
  PIPELINE_DIVERGES=1
  warn "resolved config diverges from the deployed pipeline (state dir: resolved=$RESOLVED_STATE_DIR deployed=$DEPLOYED_STATE_DIR; kokoro: resolved=$BASE_URL deployed=$DEPLOYED_KOKORO_URL) — bypassing the service, running locally same as --wait"
fi

# ── Service attempt ──────────────────────────────────────────────────────────
# herald gained a resident service (tasks 1.4/1.5): POST /notify validates,
# checks mute, enqueues, and returns in milliseconds — synthesis and delivery
# run async, and the service writes the ONE history record for the call
# itself (send.go). This script is that service's client first, falling back
# to everything below ONLY when the request could never have reached it.
#
# --wait skips this block entirely (the WAIT check below) and always runs the
# local path unchanged: it blocks through playback for evidence capture, which
# an accept-and-queue endpoint cannot express (proposal.md "## What Changes",
# "`--wait` stays local"). It is the one caller that does not want a queue.
#
# The reachable/unreachable line is the one thing this task exists to get
# right, and it is NOT "did curl exit 0":
#
#   UNREACHABLE (safe, and the ONLY case allowed to fall back) — curl never
#   established a TCP connection, or never even tried: DNS/host resolution
#   failure, connection refused, an unsupported protocol or malformed URL
#   (a misconfigured NOTIFY_SERVICE_URL), or the connect phase itself timing
#   out. Nothing was ever sent, so nothing could have been queued or
#   recorded, and falling through is the only way to avoid silencing the
#   notification (AGENTS.md fail-soft; proposal.md STOP condition #1: "the
#   service being down can silence a notification").
#
#   REACHABLE (never fall back, whatever happens next) — a TCP connection was
#   established. From that instant the service may already have accepted and
#   recorded the request even if what comes back is slow, an HTTP error
#   status, or the response read times out past --max-time: HandleNotify's
#   202 (queued) and 503 (queue full) paths both write the history record
#   themselves before or as they respond (send.go). Falling back here would
#   speak the notification a second time — proposal.md STOP condition #2,
#   named explicitly as worse than the alternative: "a double-send is worse
#   than a missed optimisation."
#
# curl conflates "the connect phase timed out" and "the response phase timed
# out" under one exit code (28, CURLE_OPERATION_TIMEDOUT), whichever of
# --connect-timeout/--max-time fired. So --connect-timeout bounds ONLY the
# connect phase (kept short: this is a loopback/tailnet call, not the
# cross-host ssh delivery further down) and --max-time bounds the whole
# request more generously; %{time_connect} from curl's write-out then tells
# the two timeout cases apart after the fact — zero means the connect phase
# itself never finished (unreachable, fall back), nonzero means a connection
# was made before anything timed out (reachable, do not fall back).
#
# Requires jq to build a well-formed JSON body (TEXT can carry quotes,
# newlines, unicode) and curl to speak HTTP; either missing degrades to the
# local path exactly as if the service were unreachable — the same posture
# record_unavailable_binary takes below on a missing herald binary.
if [ "$WAIT" -eq 0 ] && [ "$PIPELINE_DIVERGES" -eq 0 ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  REQUEST_JSON="$(jq -cn --arg text "$TEXT" --arg project "$PROJECT" '{text:$text, project:$project}')"
  SERVICE_META="$(curl -sS \
    --connect-timeout "$SERVICE_CONNECT_TIMEOUT" \
    --max-time "$SERVICE_MAX_TIME" \
    -H 'Content-Type: application/json' \
    --data-binary "$REQUEST_JSON" \
    -o /dev/null \
    -w '%{http_code} %{time_connect}' \
    "$SERVICE_URL/notify" 2>/dev/null)"
  CURL_RC=$?
  HTTP_CODE="${SERVICE_META%% *}"
  TIME_CONNECT="${SERVICE_META#* }"

  UNREACHABLE=0
  case "$CURL_RC" in
    1|3|5|6|7) UNREACHABLE=1 ;;  # never connected: bad URL/protocol, DNS, refused
    28)
      case "$TIME_CONNECT" in
        *[1-9]*) UNREACHABLE=0 ;;  # connected before the timeout hit
        *) UNREACHABLE=1 ;;        # connect phase itself never finished
      esac
      ;;
    *) UNREACHABLE=0 ;;  # 0 (success) or any failure past the connect phase —
                          # never treat it as license to speak a second time
  esac

  if [ "$UNREACHABLE" -eq 0 ]; then
    case "$HTTP_CODE" in
      2??)
        echo "notify: service accepted (HTTP $HTTP_CODE) at $SERVICE_URL, delivery async"
        ;;
      *)
        warn "service at $SERVICE_URL responded HTTP $HTTP_CODE (curl rc=$CURL_RC) — not falling back; the service already owns this attempt's history record"
        ;;
    esac
    exit 0
  fi
  warn "service at $SERVICE_URL unreachable (curl rc=$CURL_RC), falling back to the local path"
  # falls through to the local path below, unchanged
fi

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
# The remote script is shared with pkg/notify's Go delivery leg (which go:embeds
# the same file), so the two transports cannot drift. A hand-copied second copy
# was tried first and immediately lost the drainer-candidate block.
REMOTE_SPOOL_FILE="$(cd .. 2>/dev/null && pwd)/pkg/notify/remote_spool.sh"
if [ ! -r "$REMOTE_SPOOL_FILE" ]; then
  record synth_failed "remote spool script missing at $REMOTE_SPOOL_FILE"
  warn "remote spool script missing at $REMOTE_SPOOL_FILE"
  exit 0
fi
REMOTE_SPOOL="$(cat "$REMOTE_SPOOL_FILE")"

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
