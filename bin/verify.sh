#!/usr/bin/env bash
# Canonical hermetic verification for Herald.
# Deliberately excludes live/deployed acceptance and audition scripts.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

VERIFY_CONFIG_HOME=""
VERIFY_TMP=""
verify_cleanup() { rm -rf "$VERIFY_TMP" "$VERIFY_CONFIG_HOME"; }
trap verify_cleanup EXIT INT TERM
VERIFY_CONFIG_HOME="$(mktemp -d "${TMPDIR:-/tmp}/herald-verify-home.XXXXXX")"
VERIFY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/herald-verify.XXXXXX")"
HERALD_BIN="$VERIFY_TMP/herald"
export HERALD_BIN
go build -o "$HERALD_BIN" ./cmd/herald

printf '%s\n' '==> Go tests'
go test ./...

printf '%s\n' '==> Client target mapping'
VERIFY_HOME="$VERIFY_CONFIG_HOME"
trap verify_cleanup EXIT INT TERM
env -i HOME="$VERIFY_CONFIG_HOME" PATH="$PATH" HERALD_CONFIG_DIR="$VERIFY_CONFIG_HOME/.config/herald" \
  HERALD_NOTIFY_CLIENT_TARGETS="" ./bin/verify-targets.sh

# Keep this allowlist explicit: tests that touch deployed services, tailscale,
# or real playback must never become part of the default verification gate.
readonly SHELL_TESTS=(
  tests/jcode-hooks.test.sh
  tests/notify-arguments.test.sh
  tests/lib-config.test.sh
  tests/notify-config-divergence.test.sh
  tests/notify-targets.test.sh
  tests/notify-service.test.sh
  tests/notify-brief.test.sh
  tests/plugin-package.test.sh
  tests/resident-player.test.sh
  tests/spool-drainer.test.sh
)

printf '%s\n' '==> Hermetic shell tests'
for test_script in "${SHELL_TESTS[@]}"; do
  printf '    %s\n' "$test_script"
  bash -n "$test_script"
  bash "$test_script"
done

# This test launches a copied canonical gate to prove binary provenance. A
# child marker prevents that nested gate from launching the sentinel test again.
if [ "${HERALD_VERIFY_ISOLATION_CHILD:-0}" != 1 ]; then
  HERALD_VERIFY_ISOLATION_CHILD=1 bash tests/verify-binary-isolation.test.sh
fi

printf '%s\n' 'verification: all Go and hermetic shell tests passed (live/deployed tests skipped)'
