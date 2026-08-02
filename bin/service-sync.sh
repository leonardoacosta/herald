#!/usr/bin/env bash
# service-sync.sh — install and supervise `herald notify serve` on the
# EXECUTION host under systemd. The unit is generated here from the resolved
# configuration; the copy under ~/.config/systemd/user is generated output —
# never hand-edit it, edit this script and re-run.
#
# Usage:
#   service-sync.sh            install/refresh the unit -> enable -> start -> await health
#   service-sync.sh --diff     print installed unit vs generated unit, change nothing
#   service-sync.sh --status   report unit + health state, change nothing
#   service-sync.sh --remove   stop, disable, and drop the unit
#
# Third in the family with kokoro-sync.sh (execution host, docker compose) and
# player-sync.sh (playback host, launchd). Same contract, different supervisor:
# the execution host is the Arch box, so the supervisor is systemd.
#
# ── Configuration lives in a FILE, not in the unit ──────────────────────────
# This script installs the unit; it does not decide the pipeline's settings.
# Those live in $HERALD_CONFIG_DIR/config, the single instance both halves of
# the pipeline read — systemd via EnvironmentFile= below, bin/lib.sh via
# `source` for every CLI/pipe caller (proposal.md § Amendment 2026-08-01).
#
# Until that amendment this script resolved every value ONCE here and froze the
# results into literal Environment= lines. bin/notify.sh re-resolved the same
# values on every invocation, and nothing bound the two: writing a config file
# changed the pipe's behaviour immediately while the service kept serving the
# install-time snapshot until someone re-ran this script. A snapshot is not
# configuration; it is a copy that goes stale, silently, with no error anywhere.
#
# So: the file is seeded once when absent and never overwritten, the unit points
# at it, and changing a value is `$EDITOR $HERALD_CONFIG_DIR/config` followed by
# `systemctl --user restart herald-notify` — this script is not in that loop.
#
# ── USER unit, not a system unit ────────────────────────────────────────────
# The daemon must have the SAME identity and the SAME state as the pipe, or the
# consolidation this service exists for is undone: mute has to mean the same
# thing whichever path handled it. Two constraints force the choice:
#
#   1. State. The service reads and writes $HERALD_STATE_DIR (voices.json,
#      notify.ndjson, mute) under Leo's home, mode 700.
#   2. Delivery. pkg/notify/delivery.go shells `ssh -o BatchMode=yes` to the
#      playback host, which needs his ~/.ssh and the agent socket at
#      %t/ssh-agent.socket.
#
# A system unit runs as root with a different HOME and no access to either: it
# would keep a SECOND state directory under /root while the pipe kept writing
# Leo's, and every delivery would fail on publickey. Running as a user unit
# makes the daemon's view identical to the pipe's by construction.
#
# The cost of that choice is boot behaviour — a user manager without lingering
# starts at first login and stops at last logout — so install enables lingering
# rather than leaving "start on boot" half-true.
#
# Idempotent: a re-run that generates a byte-identical unit against an enabled,
# active service changes nothing and does NOT restart it. A needless restart
# would drop the listener underneath in-flight callers for no gain.
#
# Exit 0 in every branch. Failing to install the SERVICE must never be fatal:
# the CLI/pipe path is the fallback, and leaving it working is exactly what
# --remove is verified on (proposal.md — "service when up, existing CLI/pipe
# path when not").
set -uo pipefail
cd "$(dirname "$0")" || exit 0
# shellcheck disable=SC1091
source ./lib.sh

UNIT="herald-notify.service"
UNIT_DIR="$HOME/.config/systemd/user"
DEST="$UNIT_DIR/$UNIT"
CONFIG_FILE="$HERALD_CONFIG_DIR/config"
HEALTH_TIMEOUT="${HERALD_SERVICE_HEALTH_TIMEOUT:-20}"

# config_value reads one KEY out of the shared env file, empty when the file or
# the key is absent. Deliberately the same narrow grammar systemd's
# EnvironmentFile= parser accepts and bin/lib.sh's header documents — plain
# KEY=value, no shell — so this reader cannot come to a different conclusion
# than the two that matter.
config_value() {
  [ -r "$CONFIG_FILE" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$CONFIG_FILE" | tail -1
}

# notify.DefaultServePort. --status and the post-install health probe have to
# know where to look, and the answer has to come from the FILE the service
# actually reads: re-resolving the port independently here is the same
# two-resolutions-bound-to-nothing defect this task removes, just one layer up —
# an operator's exported override would aim the probe at a socket the unit never
# binds. Env and default are the fallthrough for a host not yet seeded.
resolve_port() {
  local p
  p="$(config_value HERALD_NOTIFY_PORT)"
  [ -n "$p" ] || p="${HERALD_NOTIFY_PORT:-8881}"
  printf '%s' "$p"
}
PORT="$(resolve_port)"
HEALTH_URL="http://127.0.0.1:$PORT/health"

warn() { echo "service-sync: $*" >&2; }
fail() { warn "$*"; exit 0; }

MODE="install"
case "${1:-}" in
  --diff)   MODE="diff" ;;
  --status) MODE="status" ;;
  --remove) MODE="remove" ;;
  "")       ;;
  *) fail "unknown option: $1" ;;
esac

command -v systemctl >/dev/null 2>&1 || fail "systemctl not available on this host"
systemctl --user show-environment >/dev/null 2>&1 ||
  fail "no systemd user manager for $(id -un) — run this on the execution host as the owning user"

command -v curl >/dev/null 2>&1 ||
  warn "curl not available — health checks will report no answer"

sctl() { systemctl --user "$@"; }

REPO="$(cd .. && pwd)"
STATE_DIR="$(herald_state_dir)"
BASE_URL="$(herald_config NOTIFY_KOKORO_BASE_URL HERALD_KOKORO_BASE_URL http://127.0.0.1:8880 HERDR_KOKORO_BASE_URL)"
PLAYBACK_HOST="$(herald_config NOTIFY_PLAYBACK_HOST HERALD_NOTIFY_PLAYBACK_HOST mac HERDR_NOTIFY_PLAYBACK_HOST)"
PLAYBACK_TIMEOUT="$(herald_config NOTIFY_PLAYBACK_TIMEOUT HERALD_NOTIFY_PLAYBACK_TIMEOUT 10 HERDR_NOTIFY_PLAYBACK_TIMEOUT)"
SYNTH_TIMEOUT="$(herald_config NOTIFY_SYNTH_TIMEOUT HERALD_NOTIFY_SYNTH_TIMEOUT 30 HERDR_NOTIFY_SYNTH_TIMEOUT)"
PROJECTS_TOML="$(herald_projects_toml)"
# Resolved for every mode, not just install: --diff renders the unit too, and a
# missing binary there is a reportable difference rather than a hard stop.
BIN="$(herald_bin)" || BIN=""

health() { curl -fsS --max-time 5 "$HEALTH_URL" 2>/dev/null; }

# version_of pulls the build version out of either JSON surface that carries one
# — GET /health and `herald notify status --json` both emit notify.Version(). sed
# rather than jq: nothing else in this script needs jq, and bin/notify.sh already
# treats it as optional.
version_of() { printf '%s' "$1" | sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p'; }

# render_config writes the SEED contents of the shared env file to stdout.
#
# Seed, not template: every value is what herald_config resolves right now — the
# same precedence the pipe uses (env, then the legacy NOTIFY_* config layer, then
# the documented default) — so writing the file changes no behaviour. It only
# makes what was implicit visible in one place, where editing it moves the
# service and the pipe together instead of only one of them.
#
# The names are HERALD_*, not the legacy NOTIFY_* vocabulary, because systemd
# injects these verbatim into the daemon and the daemon reads exactly these
# (notify.StateDirEnv, kokoro.BaseURLEnv, send.PlaybackHostEnv,
# notify.ServePortEnv, notify.HeraldProjectsEnv). No host address is written
# down here; they are read, not chosen (AGENTS.md § No hardcoded host addresses).
#
# The BIND address is deliberately absent: the service resolves `tailscale ip -4`
# itself at start (pkg/notify/service.go). kokoro-sync.sh has to stamp its
# equivalent in because a compose file cannot shell out; this one can.
render_config() {
  cat <<CONFIGFILE
# Herald deployed configuration — the ONE instance both halves of the pipeline
# read: systemd injects it into $UNIT via EnvironmentFile=,
# and bin/lib.sh sources it for every CLI/pipe caller.
#
# Format is the INTERSECTION of those two parsers (bin/lib.sh's header is the
# spec): plain KEY=value, blank lines and # comments fine, and NO shell — no
# export, no quoting, no expansion, no trailing comment after a value. Anything
# bash-only here is silently ignored by systemd, which is the divergence this
# file exists to prevent.
#
# Yours to edit. bin/service-sync.sh seeded this once, with the values that were
# in effect at that moment, and never overwrites it. After a change:
#   systemctl --user restart $UNIT
HERALD_NOTIFY_PORT=$PORT
HERALD_STATE_DIR=$STATE_DIR
HERALD_KOKORO_BASE_URL=$BASE_URL
HERALD_NOTIFY_PLAYBACK_HOST=$PLAYBACK_HOST
HERALD_NOTIFY_PLAYBACK_TIMEOUT=$PLAYBACK_TIMEOUT
HERALD_NOTIFY_SYNTH_TIMEOUT=$SYNTH_TIMEOUT
HERALD_PROJECTS_TOML=$PROJECTS_TOML
CONFIGFILE
}

# seed_config writes the shared env file when it is ABSENT, and never otherwise.
#
# Once written the file belongs to the operator. An installer that rewrote it on
# every run would reinstate the staleness this task removed, one layer up: the
# edit would survive exactly until the next sync, and the "single instance"
# would be single only between runs.
seed_config() {
  if [ -f "$CONFIG_FILE" ]; then
    echo "service-sync: config kept as-is — $CONFIG_FILE already exists (this script never overwrites it)"
    return 0
  fi
  mkdir -p "$HERALD_CONFIG_DIR" 2>/dev/null || true
  # Same temp-then-move as the unit below: a render that dies partway must not
  # leave systemd half a config to inject.
  if ! render_config > "$CONFIG_FILE.new" || ! mv -f "$CONFIG_FILE.new" "$CONFIG_FILE"; then
    rm -f "$CONFIG_FILE.new"
    fail "could not write $CONFIG_FILE — the unit requires it (EnvironmentFile= carries no leading dash)"
  fi
  echo "service-sync: seeded $CONFIG_FILE with the values in effect now — edit it, then \`systemctl --user restart $UNIT\`"
}

# render_unit writes the generated unit to stdout.
render_unit() {
  cat <<UNITFILE
[Unit]
Description=Herald notification service (herald notify serve)
Documentation=file:$REPO/AGENTS.md
# No After=/Wants= on tailscaled: it is a SYSTEM unit and this is a user unit,
# so the ordering cannot be expressed. The restart loop below is what actually
# covers the boot race — the listener needs a tailnet address to bind, and at
# boot tailscaled may not have one yet.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$BIN notify serve
Restart=always
RestartSec=5
# The process shuts down gracefully within notify.shutdownGrace (5s). Ten leaves
# room for that to complete on its own rather than being SIGKILLed through it.
TimeoutStopSec=10
# Deployment configuration is READ FROM A FILE, never stamped in here. The same
# file bin/lib.sh sources for every CLI/pipe caller, so the service and the pipe
# cannot describe different pipelines (proposal.md § Amendment 2026-08-01).
# Changing a value is an edit plus \`systemctl --user restart $UNIT\`;
# bin/service-sync.sh is not in that loop and does not need re-running.
#
# NO leading \`-\` on the path: a missing file is a hard start failure, on
# purpose. Starting anyway is the WORSE failure, not the fail-soft one —
# kokoro.BaseURLEnv and send.PlaybackHostEnv carry no Go-side default by
# deliberate policy (AGENTS.md § No hardcoded host addresses), so a config-less
# daemon still binds its port and still answers /health, which is enough for
# bin/notify.sh to route to it, and then it synthesises nowhere and delivers
# nowhere with nothing surfaced. Fail-soft is honoured at the layer that owns
# it: the unit refuses to start, /health does not answer, and the local CLI/pipe
# path takes the traffic — the same fallback --remove is verified on.
EnvironmentFile=$CONFIG_FILE
# The only two values that stay here are not deployment configuration at all:
# they describe the PROCESS, and mean nothing to a caller who already has a
# login shell and an agent.
#
# A daemon inherits no login shell, so PATH is explicit: the service shells
# \`tailscale\` to resolve its bind address and \`ssh\` to deliver.
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
# The on-disk key is passphraseless today and ssh succeeds without an agent, but
# the socket is where this host's units get their identity from (see
# ~/.config/systemd/user/ssh-agent.service.d) and costs nothing when unused.
Environment="SSH_AUTH_SOCK=%t/ssh-agent.socket"

[Install]
WantedBy=default.target
UNITFILE
}

case "$MODE" in
  status)
    # is-enabled/is-active both PRINT their verdict and exit non-zero on the
    # negative one, so the exit status is discarded and stdout is the answer —
    # `|| echo no` would print the verdict and "no" on two lines.
    unit_state() { local out; out="$(sctl "$1" "$UNIT" 2>/dev/null)"; printf '%s' "${out:-unknown}"; }
    echo "unit:    $([ -f "$DEST" ] && echo "installed ($DEST)" || echo missing)"
    # The config file is a start PRECONDITION now (EnvironmentFile=, no dash),
    # so its absence is the first thing to look at when the unit will not come
    # up — reporting it here saves a trip to the journal.
    echo "config:  $([ -f "$CONFIG_FILE" ] && echo "$CONFIG_FILE" || echo "MISSING ($CONFIG_FILE) — the unit cannot start without it; run this script with no arguments to seed it")"
    echo "enabled: $(unit_state is-enabled)"
    echo "active:  $(unit_state is-active)"
    echo "linger:  $(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo unknown)"
    if body="$(health)"; then
      echo "health:  ok — $HEALTH_URL answered ${body//$'\n'/}"
    else
      echo "health:  $HEALTH_URL did not answer"
    fi
    exit 0
    ;;
  diff)
    if [ ! -f "$DEST" ]; then
      echo "service-sync: not installed — $DEST absent (run without --diff to install)"
    elif render_unit | diff -q - "$DEST" >/dev/null 2>&1; then
      echo "service-sync: unit up to date ($DEST)"
    else
      echo "--- installed ($DEST) ---"
      echo "+++ generated +++"
      render_unit | diff -u "$DEST" - || true
    fi
    exit 0
    ;;
esac

# Backup before every write, same restore point kokoro-sync.sh and the rest of
# the family use.
mkdir -p "$STATE_DIR/backups" "$UNIT_DIR" 2>/dev/null || true
backup_unit() {
  [ -f "$DEST" ] || return 0
  cp -f "$DEST" "$STATE_DIR/backups/$UNIT-$(date +%Y%m%dT%H%M%S).bak" 2>/dev/null || true
}

if [ "$MODE" = "remove" ]; then
  if [ ! -f "$DEST" ] && ! sctl is-enabled "$UNIT" >/dev/null 2>&1; then
    echo "service-sync: nothing to remove — $DEST absent"
    exit 0
  fi
  backup_unit
  sctl disable --now "$UNIT" >/dev/null 2>&1 || sctl stop "$UNIT" >/dev/null 2>&1 || true
  rm -f "$DEST"
  sctl daemon-reload 2>/dev/null || true
  # Clear any failure state left behind, so a later --status reports a clean
  # absence rather than the ghost of a unit that no longer exists.
  sctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  echo "service-sync: $UNIT stopped, disabled, and removed (backup in $STATE_DIR/backups)"
  # $CONFIG_FILE is deliberately NOT deleted, for the same reason kokoro-sync.sh
  # keeps the model volume: it is the operator's, not the unit's. bin/lib.sh
  # sources that exact file for every CLI/pipe caller, so removing it here would
  # change the behaviour of the very fallback path --remove exists to leave
  # working — the removal would break the thing it is verified on. What is being
  # removed is the supervisor, not the configuration.
  [ -f "$CONFIG_FILE" ] && echo "service-sync: $CONFIG_FILE left in place — it configures the CLI/pipe path too; delete it explicitly when that is what you mean"
  if health >/dev/null; then
    warn "$HEALTH_URL still answers — something else is holding port $PORT"
  fi
  # The removal is only correct if it left the fallback intact. This is the
  # contract the whole proposal rests on, so it is asserted rather than assumed.
  if [ -x ./notify.sh ] && herald_bin >/dev/null; then
    echo "service-sync: fallback path intact — bin/notify.sh + $(herald_bin) still deliver locally"
  else
    warn "fallback path looks broken: bin/notify.sh or the herald binary is missing"
  fi
  exit 0
fi

# ── install ─────────────────────────────────────────────────────────────────
[ -n "$BIN" ] ||
  fail "herald binary not found (build it: go build -o bin/herald ./cmd/herald)"
# A binary predating task 1.4 would install a unit that fails every restart, so
# the subcommand is probed first. The probe reads the DISPATCHER's usage line
# rather than running `serve --help`: flag.ErrHelp makes every `--help` exit 1,
# so an exit status there says nothing about whether the subcommand exists. Same
# reason this is a case and not a `| grep -q` — the usage line comes with exit 1
# attached, which pipefail would propagate.
case "$("$BIN" notify 2>&1)" in
  *'|serve>'*) ;;
  *) fail "$BIN has no 'notify serve' subcommand — rebuild it: go build -o bin/herald ./cmd/herald" ;;
esac

# Before the unit, because the unit will not start without it.
seed_config
# Re-resolve now that the file exists: on a fresh host the probe above fell
# through to the default with nothing to read, and the unit binds what the file
# says.
PORT="$(resolve_port)"
HEALTH_URL="http://127.0.0.1:$PORT/health"

UNIT_CHANGED=1
if [ -f "$DEST" ] && render_unit | diff -q - "$DEST" >/dev/null 2>&1; then
  UNIT_CHANGED=0
fi

# Idempotence gate. Every condition earns its place: an identical unit that is
# disabled would not come back after a reboot, one that is enabled but inactive
# is a service that died and needs starting, and one running an OLDER BUILD than
# the binary on disk is the trap this family exists to avoid — the host copy is
# generated output, and `go build -o bin/herald` leaves the running process on
# the previous inode. Both surfaces report the same Version(), so comparing them
# is the whole check.
if [ "$UNIT_CHANGED" -eq 0 ] &&
  sctl is-enabled "$UNIT" >/dev/null 2>&1 && sctl is-active "$UNIT" >/dev/null 2>&1; then
  RUNNING="$(version_of "$(health)")"
  ONDISK="$(version_of "$("$BIN" notify status --json 2>/dev/null)")"
  if [ -z "$RUNNING" ]; then
    warn "$HEALTH_URL did not answer despite the unit being active — restarting it"
  elif [ "$RUNNING" = "$ONDISK" ] || [ -z "$ONDISK" ]; then
    echo "service-sync: already installed, enabled, and active on $RUNNING — nothing to do ($DEST)"
    exit 0
  else
    echo "service-sync: unit unchanged, but the service is running $RUNNING and $BIN is $ONDISK — restarting onto the new build"
  fi
fi

if [ "$UNIT_CHANGED" -eq 1 ]; then
  backup_unit
  # Rendered to a temp path and moved into place, so a render that dies partway
  # cannot leave systemd a truncated unit to load.
  if ! render_unit > "$DEST.new" || ! mv -f "$DEST.new" "$DEST"; then
    rm -f "$DEST.new"
    fail "could not write $DEST"
  fi
  sctl daemon-reload 2>/dev/null || fail "daemon-reload failed — unit written but not loaded"
fi

# Lingering is what makes "start on boot" true for a user unit; without it the
# user manager only exists between first login and last logout.
if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != "yes" ]; then
  loginctl enable-linger "$(id -un)" 2>/dev/null ||
    warn "could not enable lingering — the service will not start until $(id -un) logs in"
fi

sctl enable "$UNIT" >/dev/null 2>&1 || warn "could not enable $UNIT — it will not start on boot"
if ! sctl restart "$UNIT" 2>&1; then
  warn "$UNIT failed to start — the CLI/pipe path still delivers"
  sctl status "$UNIT" --no-pager -n 15 >&2
  exit 0
fi

# Await health rather than trusting `restart` returning: systemd reports a
# Type=simple unit active the moment the process is forked, which is before the
# listener is bound — and binding is the part that can fail (no tailnet address
# yet, port already held).
waited=0
while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
  health >/dev/null && break
  sleep 1
  waited=$((waited + 1))
done

if body="$(health)"; then
  echo "service-sync: $UNIT active and answering after ${waited}s — $HEALTH_URL ${body//$'\n'/}"
else
  warn "$UNIT did not answer $HEALTH_URL within ${HEALTH_TIMEOUT}s — the CLI/pipe path still delivers"
  sctl status "$UNIT" --no-pager -n 15 >&2
fi
exit 0
