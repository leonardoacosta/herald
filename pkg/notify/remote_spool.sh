SPOOL=/tmp/herald-spool
umask 077
mkdir -p "$SPOOL" || exit 1

valid_request_id() {
  case "${1:-}" in
    ""|*[!0123456789abcdef]* ) return 1 ;;
    ???????????????????????????????? ) return 0 ;;
    * ) return 1 ;;
  esac
}

list_clips() {
  find "$SPOOL" -maxdepth 1 -type f -name 'clip.*' ! -name '*.meta' -print 2>/dev/null | sort
}

cancel_pending() {
  rid="${1:-}"
  valid_request_id "$rid" || exit 0
  current=$(cat "$SPOOL/.player.current" 2>/dev/null || true)
  player_pid=$(cat "$SPOOL/.player.pid" 2>/dev/null || true)
  if [ "$current" = "$rid" ] && [ -n "$player_pid" ] && kill -0 "$player_pid" 2>/dev/null && [ -p "$SPOOL/.player.in" ]; then
    { printf 'stop\n' > "$SPOOL/.player.in" 2>/dev/null & } 2>/dev/null
  fi
  for meta in "$SPOOL"/clip.*.meta; do
    [ -f "$meta" ] || continue
    IFS= read -r meta_id < "$meta" || meta_id=""
    [ "$meta_id" = "$rid" ] || continue
    clip="${meta%.meta}"
    rm -f -- "$meta" "$clip"
    exit 0
  done
  exit 0
}

if [ -n "${HERALD_STOP_REQUEST_ID:-}" ]; then
  cancel_pending "$HERALD_STOP_REQUEST_ID"
fi

tmp=$(mktemp "$SPOOL/.incoming.XXXXXX") || exit 1
meta_tmp="$tmp.meta"
trap 'rm -f "$tmp" "$meta_tmp"' EXIT INT TERM
cat > "$tmp"
clip="$SPOOL/clip.${tmp##*.}"
if valid_request_id "${HERALD_REQUEST_ID:-}"; then
  printf '%s\n' "$HERALD_REQUEST_ID" > "$meta_tmp" || exit 1
  mv "$meta_tmp" "$clip.meta" || exit 1
fi
mv "$tmp" "$clip" || { rm -f "$clip.meta"; exit 1; }
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
claim_or_wait() {
  while ! claim; do
    find "$SPOOL" -maxdepth 1 -type f -name "clip.*" ! -name "*.meta" -print -quit 2>/dev/null | grep -q . || exit 0
    sleep 0.1
  done
}
trap "" HUP
trap cleanup EXIT INT TERM
	claim_or_wait
	while :; do
	  while :; do
	    batch=$(find "$SPOOL" -maxdepth 1 -type f -name "clip.*" ! -name "*.meta" -print 2>/dev/null | sort)
	    [ -n "$batch" ] || break
	    joined="$SPOOL/.playing.$$"
	    cat $batch > "$joined" 2>/dev/null
	    afplay "$joined" >/dev/null 2>&1
	    for clip in $batch; do rm -f "$clip" "$clip.meta"; done
	    rm -f "$joined"
	  done
	  HELD=0
	  rm -rf "$LOCK"
	  find "$SPOOL" -maxdepth 1 -type f -name "clip.*" ! -name "*.meta" -print -quit 2>/dev/null | grep -q . || exit 0
	  claim_or_wait
	done
' </dev/null >/dev/null 2>&1 &

if [ "${HERALD_WAIT:-0}" = "1" ]; then
  while [ -e "$clip" ]; do sleep 0.2; done
fi
