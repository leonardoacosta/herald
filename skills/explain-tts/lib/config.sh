# shellcheck shell=bash
# explain-tts configuration.
# Precedence: defaults below <- unmanaged host override file <- inherited environment.
# EXPLAIN_TTS_* environment variables and config.sh overrides are supported.

: "${EXPLAIN_TTS_HOME:=$HOME}"

# Generic defaults; set deployment-specific values in the override file.
: "${EXPLAIN_TTS_BASE_URL:=http://127.0.0.1:8880}"
: "${EXPLAIN_TTS_MODEL:=kokoro}"
: "${EXPLAIN_TTS_VOICE:=af_heart+af_bella(3)}"
: "${EXPLAIN_TTS_SPEED:=0.95}"
: "${EXPLAIN_TTS_FORMAT:=mp3}"
: "${EXPLAIN_TTS_SSH_HOST:=}"
: "${EXPLAIN_TTS_SYNTH_TIMEOUT:=25}"
: "${EXPLAIN_TTS_PLAYBACK_TIMEOUT:=12}"
: "${EXPLAIN_TTS_REMOTE_FALLBACK:=0}"
: "${EXPLAIN_TTS_REMOTE_FIRST:=0}"

EXPLAIN_TTS_CONFIG_DIR="${EXPLAIN_TTS_CONFIG_DIR:-$EXPLAIN_TTS_HOME/.config/explain-tts}"
EXPLAIN_TTS_STATE_DIR="${EXPLAIN_TTS_STATE_DIR:-$EXPLAIN_TTS_HOME/.local/state/explain-tts}"
EXPLAIN_TTS_OPTIONS_FILE="$EXPLAIN_TTS_CONFIG_DIR/options.env"
EXPLAIN_TTS_HISTORY_FILE="$EXPLAIN_TTS_STATE_DIR/history.ndjson"

if [ -r "$EXPLAIN_TTS_CONFIG_DIR/config.sh" ]; then
  # shellcheck disable=SC1091
  . "$EXPLAIN_TTS_CONFIG_DIR/config.sh"
fi

# User options are data, not shell code. Load only the supported KEY=VALUE lines.
if [ -r "$EXPLAIN_TTS_OPTIONS_FILE" ]; then
  while IFS='=' read -r _et_key _et_value; do
    case "$_et_key" in
      VOICE) [ -n "$_et_value" ] && EXPLAIN_TTS_VOICE="$_et_value" ;;
      SPEED) [ -n "$_et_value" ] && EXPLAIN_TTS_SPEED="$_et_value" ;;
      MUTE_UNTIL) # shellcheck disable=SC2034
        EXPLAIN_TTS_MUTE_UNTIL="$_et_value" ;;
    esac
  done < "$EXPLAIN_TTS_OPTIONS_FILE"
fi

explain_tts_self() {
  _et_self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  printf '%s\n' "$_et_self"
}

explain_tts_record() {
  # explain_tts_record <outcome> <preset> <chars> <chunks> <detail>
  _et_dir="$(dirname "$EXPLAIN_TTS_HISTORY_FILE")"
  mkdir -p "$_et_dir" 2>/dev/null
  _et_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  _et_detail="$(printf '%s' "${5:-}" | tr '\n' ' ' | cut -c1-200)"
  printf '{"ts":"%s","outcome":"%s","preset":"%s","chars":%s,"chunks":%s,"detail":"%s"}\n' \
    "$_et_ts" "$1" "${2:-}" "${3:-0}" "${4:-1}" "$_et_detail" \
    >> "$EXPLAIN_TTS_HISTORY_FILE" 2>/dev/null
}

explain_tts_effective() {
  # Print effective KEY=VALUE options: defaults, then persisted overrides.
  printf 'BASE_URL=%s\nMODEL=%s\nVOICE=%s\nSPEED=%s\nFORMAT=%s\nSSH_HOST=%s\n' \
    "$EXPLAIN_TTS_BASE_URL" "$EXPLAIN_TTS_MODEL" "$EXPLAIN_TTS_VOICE" \
    "$EXPLAIN_TTS_SPEED" "$EXPLAIN_TTS_FORMAT" "$EXPLAIN_TTS_SSH_HOST"
  if [ -r "$EXPLAIN_TTS_OPTIONS_FILE" ]; then
    grep -E '^(VOICE|SPEED|MUTE_UNTIL)=' "$EXPLAIN_TTS_OPTIONS_FILE"
  fi
}
