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

# ── Shared-file contract (notify-service task 4.1 amendment) ────────────────
# bin/lib.sh sources $HERALD_CONFIG_DIR/config directly (not through
# herald_config), so this exercises the precedence promise in its own header
# comment rather than herald_config's four-way fallback above. Each case
# sources lib.sh in its own `bash -c` subshell: this process already sourced
# it once above, and a second `source` here would run the inherited-variable
# snapshot against variables THIS file's own assertions exported, not a
# caller's.
CONFIG_TMP="$TMP/shared-config"
mkdir -p "$CONFIG_TMP"
cat > "$CONFIG_TMP/config" <<'CONF'
# comments and blank lines are skipped by both parsers (bin/lib.sh's header)

HERALD_STATE_DIR=/from/shared/file
HERALD_KOKORO_BASE_URL=http://127.0.0.1:9999
CONF

# The file is honored when nothing was exported: HERALD_STATE_DIR is
# defaulted (and exported) by bin/lib.sh itself before the file is sourced,
# but that default is not an inherited override, so the file's value wins.
# `env -u` drops THIS script's own HERALD_STATE_DIR export (line 10 above) —
# without it the subshell would inherit that as if the caller had set it.
# shellcheck disable=SC2016  # deliberately literal: these expand in the bash
# -c CHILD after `source "$1"` runs, not in this parent script — shellcheck's
# heuristic flags it only because this file also assigns HERALD_STATE_DIR
# itself, above, for the earlier project-registry cases.
OUT="$(env -u HERALD_STATE_DIR HOME="$TMP/home2" HERALD_CONFIG_DIR="$CONFIG_TMP" \
  bash -c 'source "$1"; printf "%s %s" "$HERALD_STATE_DIR" "$HERALD_KOKORO_BASE_URL"' \
  _ "$REPO/bin/lib.sh")"
[ "$OUT" = "/from/shared/file http://127.0.0.1:9999" ] ||
  { echo "shared file was not honored when nothing was exported: $OUT" >&2; exit 1; }

# An explicitly-exported env var still beats the file — the precondition
# task 4.1 fixed (bin/lib.sh used to default HERALD_STATE_DIR before sourcing
# the file, so the file clobbered a caller's inherited value outright).
OUT="$(HOME="$TMP/home2" HERALD_CONFIG_DIR="$CONFIG_TMP" HERALD_STATE_DIR="/from/env" \
  bash -c 'source "$1"; printf "%s" "$HERALD_STATE_DIR"' \
  _ "$REPO/bin/lib.sh")"
[ "$OUT" = "/from/env" ] ||
  { echo "an inherited env var did not beat the shared file: $OUT" >&2; exit 1; }

echo "lib config: shared-file contract (file honored, inherited env wins) passed"
