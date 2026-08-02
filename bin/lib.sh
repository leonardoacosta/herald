#!/usr/bin/env bash
# Shared configuration and state helpers for Herald. Source, don't execute.
#
# ── $HERALD_CONFIG_DIR/config is a SHARED file, not a shell file ───────────
# This same file is read by two different parsers: bash `source` here, and
# systemd `EnvironmentFile=` (bin/service-sync.sh task 4.2) when the service
# is deployed. One instance of the deployed configuration, not two
# independent resolutions that only happen to agree (proposal.md § Amendment
# 2026-08-01). That convergence is only possible in the INTERSECTION of what
# both readers accept, so the format is constrained to:
#
#   - plain `KEY=value` lines, one per line; blank lines and `#` comments are
#     fine (both parsers skip them)
#   - NO shell: no `export`, no quoting, no command substitution, no
#     variable expansion, no inline comments after a value — systemd's
#     EnvironmentFile= parser does none of this, and anything bash-only here
#     would silently diverge between the two readers
#   - `HERALD_*` names — the names the service actually reads (pkg/notify's
#     StateDirEnv, kokoro.BaseURLEnv, send.PlaybackHostEnv, ...), not the
#     `NOTIFY_*` vocabulary `herald_config` below also accepts as a legacy,
#     shell-only config-file layer. A file meant for systemd has to carry the
#     names the service actually reads, or systemd injects nothing useful.
#
# ── Precedence: an inherited env var still beats this file ─────────────────
# `source` is a plain assignment: a config file naming a variable
# unconditionally overwrites it, including a value the CALLER explicitly
# exported before invoking this script. Unguarded, that makes the shared
# file stronger than an explicit override — backwards from every other
# precedence rule here (see `herald_config`: env > legacy env > config file
# > default).
#
# The fix: snapshot which HERALD_* variables are ALREADY exported before
# this script assigns anything (its own defaults included — a value THIS
# script defaults, like HERALD_STATE_DIR two lines below, is not an
# inherited override and must stay overridable by the file), source the
# file, then restore exactly those snapshotted values afterward. Captured
# via `compgen -e` (bash's list of currently-exported names) and indirect
# expansion rather than parsing `env` text, so a value containing `=` or
# other punctuation round-trips exactly instead of being reconstructed.
declare -A __herald_inherited=()
while IFS= read -r __hv; do
  [ -n "$__hv" ] || continue
  __herald_inherited["$__hv"]="${!__hv}"
done < <(compgen -e HERALD_ 2>/dev/null || true)

HERALD_CONFIG_DIR="${HERALD_CONFIG_DIR:-$HOME/.config/herald}"
HERALD_STATE_DIR="${HERALD_STATE_DIR:-$HOME/.local/state/herald}"
export HERALD_STATE_DIR
mkdir -p "$HERALD_CONFIG_DIR" "$HERALD_STATE_DIR/backups" 2>/dev/null || true

# Shell configuration is optional. A missing or unreadable file degrades to
# environment variables and documented defaults.
# shellcheck disable=SC1090,SC1091
[ -r "$HERALD_CONFIG_DIR/config" ] && source "$HERALD_CONFIG_DIR/config" 2>/dev/null || true

# Restore every variable that was already inherited to its pre-source value —
# the file may have just reassigned it above, and an explicit inherited
# value wins over the file every time.
for __hv in "${!__herald_inherited[@]}"; do
  export "$__hv=${__herald_inherited[$__hv]}"
done
unset __herald_inherited __hv

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
