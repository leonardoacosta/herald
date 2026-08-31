#!/usr/bin/env bash
# Canonical hermetic verification for Herald.
# Deliberately excludes live/deployed acceptance and audition scripts.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

printf '%s\n' '==> Go tests'
go test ./...

# Keep this allowlist explicit: tests that touch deployed services, tailscale,
# or real playback must never become part of the default verification gate.
readonly SHELL_TESTS=(
  tests/jcode-hooks.test.sh
  tests/lib-config.test.sh
  tests/notify-config-divergence.test.sh
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

printf '%s\n' 'verification: all Go and hermetic shell tests passed (live/deployed tests skipped)'
