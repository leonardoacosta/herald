#!/usr/bin/env bash
# Shared configuration and state helpers for Herald. Source, don't execute.

HERALD_CONFIG_DIR="${HERALD_CONFIG_DIR:-$HOME/.config/herald}"
HERALD_STATE_DIR="${HERALD_STATE_DIR:-$HOME/.local/state/herald}"
export HERALD_STATE_DIR
mkdir -p "$HERALD_CONFIG_DIR" "$HERALD_STATE_DIR/backups" 2>/dev/null || true

# Shell configuration is optional. A missing or unreadable file degrades to
# environment variables and documented defaults.
# shellcheck disable=SC1090,SC1091
[ -r "$HERALD_CONFIG_DIR/config" ] && source "$HERALD_CONFIG_DIR/config" 2>/dev/null || true

# herald_config <CONFIG_VAR> <ENV_VAR> [default] [legacy-env-var]
#
# New environment variables win, followed by a one-release legacy environment
# fallback, the config file, and the documented default.
herald_config() {
  local cvar="${1:?config var name}" evar="${2:?env var name}"
  local default="${3:-}" legacy="${4:-}" v
  v="${!evar:-}"
  [ -n "$v" ] || [ -z "$legacy" ] || v="${!legacy:-}"
  [ -n "$v" ] || v="${!cvar:-}"
  [ -n "$v" ] || v="$default"
  printf '%s\n' "$v"
}

# Herald's state resolver mirrors pkg/notify.ResolveStateDir.
herald_state_dir() {
  printf '%s\n' "${HERALD_STATE_DIR:-$HOME/.local/state/herald}"
}

# Canonical projects.toml path. The Herald variable wins, followed by the
# one-release Shepherd fallback, DOTFILES, and the installfest default.
herald_projects_toml() {
  local path
  path="${HERALD_PROJECTS_TOML:-}"
  [ -n "$path" ] || path="${SHEPHERD_PROJECTS_TOML:-}"
  [ -n "$path" ] || path="${DOTFILES:-$HOME/dev/personal/installfest}/home/projects.toml"
  printf '%s\n' "$path"
}

# Path to the herald binary, or 1 if no executable can be found.
herald_bin() {
  if [ -n "${HERALD_BIN:-}" ] && [ -x "$HERALD_BIN" ]; then
    printf '%s\n' "$HERALD_BIN"
    return 0
  fi
  local repo candidate
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  for candidate in "$repo/bin/herald" "$HOME/.local/bin/herald"; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  command -v herald 2>/dev/null && return 0
  return 1
}
