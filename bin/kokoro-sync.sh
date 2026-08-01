#!/usr/bin/env bash
# kokoro-sync.sh — install Herald's kokoro compose module onto the
# execution host, bring the service up, and verify it is healthy. The module
# shipped in this repo (compose/kokoro.yml) is the source of truth; the copy on
# the host is generated output — never hand-edit it, edit the repo copy and
# re-run this.
#
# Usage:
#   kokoro-sync.sh            backup -> install module -> up -d -> await health
#   kokoro-sync.sh --diff     print installed module vs repo module, change nothing
#   kokoro-sync.sh --remove   compose down + drop the installed module (backup first)
#
# Same contract as jobs-sync.sh, for the same reason: this owns a slice of a
# host the plugin does not otherwise control. Every write backs the current
# installed module up to Herald's state backups first, and only Herald's own
# compose project is ever touched, and anything else on the host's docker is
# untouched — the module declares `name: herald-kokoro`, so `compose down` can
# never reach another stack's containers.
#
# Idempotent: a re-run with an unchanged module copies a byte-identical file,
# `up -d` is a no-op on an already-running healthy container, and the health
# wait returns immediately.
#
# --remove deliberately does NOT delete the model volume. The volume is the
# expensive artifact (a multi-GB baked model); dropping it would turn a
# reinstall into a re-download. Remove it explicitly with
# `docker volume rm herald-kokoro_kokoro-models` when that is what you mean.
#
# Exit 0 in every branch.
set -uo pipefail
cd "$(dirname "$0")" || exit 0
# shellcheck disable=SC1091
source ./lib.sh

SOURCE="$(cd .. && pwd)/compose/kokoro.yml"
DEST="${HERALD_KOKORO_COMPOSE:-${SHEPHERD_KOKORO_COMPOSE:-$HERALD_STATE_DIR/compose/kokoro.yml}}"
PROJECT="herald-kokoro"
HEALTH_URL="${HERALD_KOKORO_HEALTH_URL:-${SHEPHERD_KOKORO_HEALTH_URL:-http://127.0.0.1:8880/health}}"
# The container's own start_period is 180s (CPU model load); allow for that plus
# an image pull on a cold host before giving up.
HEALTH_TIMEOUT="${HERALD_KOKORO_HEALTH_TIMEOUT:-${SHEPHERD_KOKORO_HEALTH_TIMEOUT:-300}}"

MODE="install"
case "${1:-}" in
  --diff) MODE="diff" ;;
  --remove) MODE="remove" ;;
esac

fail() { echo "kokoro-sync: $*" >&2; exit 0; }
[ -f "$SOURCE" ] || fail "compose module not found: $SOURCE"
command -v docker >/dev/null 2>&1 || fail "docker not available on this host"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin not available on this host"

# The compose module binds a published port to the tailnet address. Resolve it
# here rather than baking one host's address into the module: the module's
# default is only a fallback for a bare `docker compose -f` invocation.
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$TS_IP" ] && export KOKORO_BIND_TAILSCALE_IP="$TS_IP"
fi

compose() { docker compose -p "$PROJECT" -f "$DEST" "$@"; }

if [ "$MODE" = "diff" ]; then
  if [ ! -f "$DEST" ]; then
    echo "kokoro-sync: not installed — $DEST absent (run without --diff to install)"
  elif cmp -s "$SOURCE" "$DEST"; then
    echo "kokoro-sync: module up to date ($DEST)"
  else
    echo "--- installed ($DEST) ---"
    echo "+++ repo ($SOURCE) +++"
    diff -u "$DEST" "$SOURCE"
  fi
  exit 0
fi

# Backup (the installed module, into the plugin-wide restore point).
mkdir -p "$HERALD_STATE_DIR/backups" "$(dirname "$DEST")"
if [ -f "$DEST" ]; then
  cp -f "$DEST" "$HERALD_STATE_DIR/backups/kokoro-$(date +%Y%m%dT%H%M%S).yml.bak" 2>/dev/null || true
fi

if [ "$MODE" = "remove" ]; then
  if [ -f "$DEST" ]; then
    if compose down 2>&1; then
      echo "kokoro-sync: compose project '$PROJECT' brought down (model volume kept)"
    else
      echo "kokoro-sync: compose down FAILED — module left in place, backup in $HERALD_STATE_DIR/backups" >&2
      exit 0
    fi
    rm -f "$DEST"
    echo "kokoro-sync: module removed (backup in $HERALD_STATE_DIR/backups)"
  else
    echo "kokoro-sync: nothing to remove — $DEST absent"
  fi
  exit 0
fi

# Install: copy, then validate the installed copy before acting on it. A module
# that does not parse must never reach `up -d`, where compose would act on a
# partial project.
cp -f "$SOURCE" "$DEST" || fail "could not write $DEST"
if ! compose config --quiet 2>&1; then
  echo "kokoro-sync: installed module failed validation — service left untouched" >&2
  exit 0
fi

if ! compose up -d 2>&1; then
  echo "kokoro-sync: compose up FAILED — see output above, backup in $HERALD_STATE_DIR/backups" >&2
  exit 0
fi

# Await health: the container's own healthcheck is authoritative (it knows the
# start_period), and the HTTP probe is the cross-check that the published bind
# actually answers on the host — a healthy container behind a misbound port is
# exactly the failure this script exists to catch.
echo "kokoro-sync: waiting up to ${HEALTH_TIMEOUT}s for the container to report healthy..."
waited=0
status=""
while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
  status="$(docker inspect -f '{{.State.Health.Status}}' kokoro 2>/dev/null || echo "")"
  [ "$status" = "healthy" ] && break
  if [ "$status" = "unhealthy" ]; then
    echo "kokoro-sync: container reported UNHEALTHY after ${waited}s" >&2
    compose logs --tail 30 2>&1 >&2
    exit 0
  fi
  sleep 5
  waited=$((waited + 5))
done

if [ "$status" != "healthy" ]; then
  echo "kokoro-sync: container did not report healthy within ${HEALTH_TIMEOUT}s (last status: ${status:-unknown})" >&2
  compose logs --tail 30 2>&1 >&2
  exit 0
fi

if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
  echo "kokoro-sync: installed and healthy after ${waited}s ($HEALTH_URL answering, module at $DEST)"
else
  echo "kokoro-sync: container healthy after ${waited}s but $HEALTH_URL did not answer from the host — check the published bind" >&2
fi
exit 0
