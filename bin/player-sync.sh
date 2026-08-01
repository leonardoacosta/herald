#!/usr/bin/env bash
# player-sync.sh — install Herald's resident spool player onto the PLAYBACK
# host (the Mac) and register its launchd user agent. The script shipped in this
# repo (bin/herald-player.sh) is the source of truth; the copy on the host is
# generated output — never hand-edit it, edit the repo copy and re-run this.
#
# Usage:
#   player-sync.sh            install script + agent -> load -> verify running
#   player-sync.sh --diff     print installed script vs repo script, change nothing
#   player-sync.sh --remove   unload the agent + drop the installed files
#   player-sync.sh --status   report agent + process state, change nothing
#
# Same contract and shape as kokoro-sync.sh, for the same reason: this owns a
# slice of a host the repo does not otherwise control. The difference is which
# host — kokoro-sync targets the execution host over local docker, this targets
# the playback host over ssh, using the same PLAYBACK_HOST the notify pipe uses
# so there is exactly one place that names it.
#
# Idempotent: re-running with an unchanged script copies a byte-identical file,
# and `launchctl kickstart -k` restarts an already-loaded agent rather than
# erroring on a duplicate label.
#
# Exit 0 in every branch. Failing to install a LATENCY OPTIMISATION must never
# be fatal: a host with no player still gets every notification through the
# fallback drainer, which is the whole reason the spool is the interface.
set -uo pipefail
cd "$(dirname "$0")" || exit 0
# shellcheck disable=SC1091
source ./lib.sh

SOURCE="$(pwd)/herald-player.sh"
PLAYBACK_HOST="$(herald_config NOTIFY_PLAYBACK_HOST HERALD_NOTIFY_PLAYBACK_HOST mac HERDR_NOTIFY_PLAYBACK_HOST)"
LABEL="dev.herald.player"
REMOTE_BIN="\$HOME/.local/bin/herald-player"
REMOTE_PLIST="\$HOME/Library/LaunchAgents/$LABEL.plist"

warn() { echo "player-sync: $*" >&2; }

MODE="install"
case "${1:-}" in
  --diff)   MODE="diff" ;;
  --remove) MODE="remove" ;;
  --status) MODE="status" ;;
  "")       ;;
  *) warn "unknown option: $1"; exit 0 ;;
esac

sshx() { ssh -o BatchMode=yes "$PLAYBACK_HOST" "$@"; }

sshx true 2>/dev/null || { warn "playback host $PLAYBACK_HOST unreachable — nothing installed"; exit 0; }

case "$MODE" in
  status)
    sshx "bash -s" <<EOS
echo "agent:   \$(launchctl list 2>/dev/null | grep -c '$LABEL' | tr -d ' ') registered"
echo "process: \$(pgrep -f 'herald-player' | wc -l | tr -d ' ') running"
echo "script:  \$([ -x "$REMOTE_BIN" ] && echo installed || echo missing)"
echo "plist:   \$([ -f "$REMOTE_PLIST" ] && echo installed || echo missing)"
EOS
    exit 0
    ;;
  diff)
    sshx "cat $REMOTE_BIN 2>/dev/null" > /tmp/herald-player.installed.$$ 2>/dev/null || true
    if diff -u /tmp/herald-player.installed.$$ "$SOURCE" > /tmp/herald-player.diff.$$ 2>/dev/null; then
      echo "player-sync: installed script matches the repo copy"
    else
      cat /tmp/herald-player.diff.$$
    fi
    rm -f /tmp/herald-player.installed.$$ /tmp/herald-player.diff.$$
    exit 0
    ;;
  remove)
    sshx "bash -s" <<EOS
launchctl bootout "gui/\$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$REMOTE_PLIST" 2>/dev/null || true
pkill -f herald-player 2>/dev/null || true
rm -f "$REMOTE_BIN" "$REMOTE_PLIST"
echo "player-sync: agent unloaded and files removed"
EOS
    exit 0
    ;;
esac

# ── install ─────────────────────────────────────────────────────────────────
# The script is written to a temp path and moved into place, so a player already
# running from that inode is never rewritten underneath itself.
sshx "mkdir -p \$HOME/.local/bin \$HOME/Library/LaunchAgents && cat > \$HOME/.local/bin/.herald-player.new" < "$SOURCE" || {
  warn "could not copy the player script"; exit 0; }
sshx "chmod +x \$HOME/.local/bin/.herald-player.new && mv \$HOME/.local/bin/.herald-player.new $REMOTE_BIN" || {
  warn "could not install the player script"; exit 0; }

# The silence track the player uses to hold the output stream open between
# clips. Generated once on the host rather than committed: it is 1.8MB of
# nothing, and ffmpeg is already present wherever mpg123 is. Its length must
# exceed HERALD_PLAYER_IDLE (default 900s) or the device powers down while the
# player still thinks it is warm. Absence is not fatal — the player degrades to
# the ~500ms cold path, which is still better than a process per clip.
sshx "bash -s" <<'EOS'
mkdir -p "$HOME/.local/share/herald"
SIL="$HOME/.local/share/herald/silence.mp3"
if [ ! -s "$SIL" ]; then
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -f lavfi -i anullsrc=r=24000:cl=mono -t 1800 -q:a 9 -y "$SIL" >/dev/null 2>&1 \
      && echo "player-sync: generated keep-warm silence ($(wc -c < "$SIL" | tr -d ' ') bytes)" \
      || echo "player-sync: could not generate silence — player runs without keep-warm"
  else
    echo "player-sync: no ffmpeg — player runs without keep-warm (~500ms per clip)"
  fi
fi
EOS

# KeepAlive restarts it on crash; RunAtLoad starts it at login. Both are the
# point of choosing launchd over a self-respawning process (proposal § Decisions).
# PATH is set explicitly because a launchd agent does not inherit a login shell's
# environment, and mpg123 lives in Homebrew's prefix.
sshx "bash -s" <<EOS
cat > "$REMOTE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>\$HOME/.local/bin/herald-player</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>/tmp/herald-player.log</string>
</dict>
</plist>
PLIST
UID_N=\$(id -u)
# bootout is ASYNCHRONOUS. Bootstrapping straight after it races the teardown and
# fails with "service already loaded" — and because every launchctl call here was
# once suffixed with '|| true', that failure was silent and left NO agent
# registered at all while this script still reported success (observed
# 2026-08-01). Wait for the label to actually disappear, then report what
# bootstrap really did.
launchctl bootout "gui/\$UID_N/$LABEL" 2>/dev/null || true
for _ in \$(seq 1 25); do
  launchctl print "gui/\$UID_N/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
if ! launchctl bootstrap "gui/\$UID_N" "$REMOTE_PLIST" 2>/tmp/herald-bootstrap.err; then
  # Older macOS has no bootstrap subcommand; load is the documented equivalent.
  if ! launchctl load "$REMOTE_PLIST" 2>>/tmp/herald-bootstrap.err; then
    echo "BOOTSTRAP_FAILED: \$(tr '\n' ' ' < /tmp/herald-bootstrap.err)"
  fi
fi
# RunAtLoad already starts it; kickstart without -k only nudges it if it did not
# start, where -k would kill a healthy player and hand its lock to a successor.
launchctl kickstart "gui/\$UID_N/$LABEL" 2>/dev/null || true
EOS

# Verify the AGENT is registered as well as a process being up. Checking only for
# a process is what let a failed bootstrap read as success: the outgoing player
# was still dying and pgrep found it.
sleep 2
STATE=$(sshx "bash -s" <<EOS
echo "agent=\$(launchctl list 2>/dev/null | grep -c '$LABEL' | tr -d ' ')"
echo "procs=\$(pgrep -f herald-player | wc -l | tr -d ' ')"
echo "lockpid=\$(cat /tmp/herald-spool/drainer.lock/pid 2>/dev/null)"
echo "playerpid=\$(pgrep -f herald-player | head -1)"
EOS
)
AGENT=$(printf '%s' "$STATE" | sed -n 's/^agent=//p')
PROCS=$(printf '%s' "$STATE" | sed -n 's/^procs=//p')
LOCKPID=$(printf '%s' "$STATE" | sed -n 's/^lockpid=//p')
PLAYERPID=$(printf '%s' "$STATE" | sed -n 's/^playerpid=//p')

if [ "${AGENT:-0}" -ge 1 ] && [ "${PROCS:-0}" -ge 1 ]; then
  echo "player-sync: resident player running on $PLAYBACK_HOST (agent $LABEL, pid ${PLAYERPID:-?})"
  # The player must own the spool lock, or a fallback drainer can play alongside
  # it — the overlap serial-playback exists to prevent.
  if [ -n "$LOCKPID" ] && [ "$LOCKPID" != "$PLAYERPID" ]; then
    warn "spool lock is held by pid $LOCKPID, not the player ($PLAYERPID) — investigate before relying on this"
  fi
else
  warn "no resident player on $PLAYBACK_HOST (agent=${AGENT:-0} procs=${PROCS:-0}) — notifications fall back to the per-clip drainer"
  sshx "tail -5 /tmp/herald-player.log 2>/dev/null" || true
fi
exit 0
