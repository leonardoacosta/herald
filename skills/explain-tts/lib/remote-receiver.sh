#!/bin/sh
# explain-tts remote receiver. Runs on the logged-in Mac via SSH and plays one
# or more MP3 clips through the user's CoreAudio session.
SPOOL=/tmp/herald-spool
LOG="$SPOOL/explain-tts.log"
umask 077
mkdir -p "$SPOOL" || exit 1
log() { printf '%s explain-tts: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null; }

tmp=$(mktemp "$SPOOL/.incoming.XXXXXX") || { log "receive failed stage=mktemp"; exit 1; }
trap 'rm -f "$tmp"' EXIT INT TERM
cat > "$tmp" || { log "receive failed stage=stdin"; exit 1; }
bytes=$(wc -c < "$tmp" | tr -d ' ')
log "received bytes=$bytes source=ssh"
clip="$SPOOL/clip.${tmp##*.}"
mv "$tmp" "$clip" || { log "receive failed stage=move"; exit 1; }
trap - EXIT INT TERM

LOCK="$SPOOL/drainer.lock"
while ! mkdir "$LOCK" 2>/dev/null; do
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$LOCK"
  else
    sleep 0.1
  fi
done
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT INT TERM

for f in $(find "$SPOOL" -maxdepth 1 -type f -name 'clip.*' ! -name '*.meta' -print | sort); do
  started=$(date +%s)
  afplay "$f"
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  log "playback file=$(basename "$f") rc=$rc seconds=$elapsed"
  [ "$rc" = 0 ] || exit "$rc"
  rm -f "$f"
done
exit 0
