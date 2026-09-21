#!/usr/bin/env bash
# Read-only operational check for identity-to-SSH-host deployment mapping.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./lib.sh

mapping="${HERALD_NOTIFY_CLIENT_TARGETS:-}"
herald_validate_client_targets "$mapping"
printf 'client target configuration: %s/config\n' "$HERALD_CONFIG_DIR"
if [ -z "${mapping//[[:space:]]/}" ]; then
  echo 'client targets: none configured (static playback fallback remains active)'
  exit 0
fi
echo 'client targets:'
IFS=',' read -ra entries <<< "$mapping"
for entry in "${entries[@]}"; do
  printf '  %s\n' "${entry%%=*}"
done
echo 'validation: passed (no hosts contacted)'
