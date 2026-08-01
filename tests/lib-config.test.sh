#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t herald-lib-config.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

export HOME="$TMP/home"
export HERALD_CONFIG_DIR="$TMP/config"
export HERALD_STATE_DIR="$TMP/state"
# shellcheck disable=SC1091
source "$REPO/bin/lib.sh"

export HERALD_PROJECTS_TOML="$TMP/primary.toml"
export SHEPHERD_PROJECTS_TOML="$TMP/legacy.toml"
export DOTFILES="$TMP/dotfiles"
[ "$(herald_projects_toml)" = "$TMP/primary.toml" ]

unset HERALD_PROJECTS_TOML
[ "$(herald_projects_toml)" = "$TMP/legacy.toml" ]

unset SHEPHERD_PROJECTS_TOML
[ "$(herald_projects_toml)" = "$TMP/dotfiles/home/projects.toml" ]

echo "lib config: project registry precedence passed"
