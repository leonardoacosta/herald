#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-targets.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" HERALD_CONFIG_DIR="$TMP/config"
mkdir -p "$HOME" "$HERALD_CONFIG_DIR"
source "$REPO/bin/lib.sh"
herald_validate_client_targets 'laptop=bb-mac, phone=phone-host'
! herald_validate_client_targets 'laptop=' 2>/dev/null
! herald_validate_client_targets 'laptop=host, laptop=other' 2>/dev/null
! herald_validate_client_targets 'bad identity=host' 2>/dev/null
cat > "$HERALD_CONFIG_DIR/config" <<'CONF'
HERALD_NOTIFY_CLIENT_TARGETS=laptop=bb-mac,phone=phone-host
CONF
out="$($REPO/bin/verify-targets.sh)"
