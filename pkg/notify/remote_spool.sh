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
