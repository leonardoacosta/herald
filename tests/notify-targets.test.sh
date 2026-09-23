#!/usr/bin/env bash
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-targets.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" HERALD_CONFIG_DIR="$TMP/config"
mkdir -p "$HOME" "$HERALD_CONFIG_DIR"
source "$REPO/bin/lib.sh"
herald_validate_client_targets 'laptop=bb-mac, phone=phone-host'
while IFS= read -r case_json; do
  name="$(jq -r '.name' <<<"$case_json")"
  mapping="$(jq -r '.mapping' <<<"$case_json")"
  expected="$(jq -r '.valid' <<<"$case_json")"
  actual=true
  herald_validate_client_targets "$mapping" >/dev/null 2>&1 || actual=false
  [ "$actual" = "$expected" ] || { echo "$name: validator=$actual expected=$expected" >&2; exit 1; }
done < <(jq -c '.[]' "$REPO/tests/fixtures/client-targets.json")
cat > "$HERALD_CONFIG_DIR/config" <<'CONF'
HERALD_NOTIFY_CLIENT_TARGETS=laptop=bb-mac,phone=phone-host
CONF
out="$($REPO/bin/verify-targets.sh)"
