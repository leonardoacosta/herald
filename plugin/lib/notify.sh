#!/usr/bin/env bash
# notify.sh — sourceable Herald caller helper shipped by the notify plugin.
# say_notify is bounded, fire-and-forget, and always returns 0.

(return 0 2>/dev/null) || set -euo pipefail

_NOTIFY_DIR=""
if [ -n "${BASH_SOURCE:-}" ]; then
  _NOTIFY_DIR="$(dirname "${BASH_SOURCE[0]}")"
elif [ -n "${ZSH_VERSION:-}" ]; then
  # shellcheck disable=SC2296
  _NOTIFY_DIR="$(dirname "${(%):-%x}")"
fi
# shellcheck source=plugin/lib/projects-toml.sh
source "${_NOTIFY_DIR}/projects-toml.sh" 2>/dev/null || true
unset _NOTIFY_DIR

_notify_pipe() {
  [ -n "${HERALD:-}" ] || return 0
  local root="$HERALD"
  case "$root" in
    \~/*) root="$HOME/${root#\~/}" ;;
  esac
  local pipe="$root/bin/notify.sh"
  [ -x "$pipe" ] || return 0
  printf '%s' "$pipe"
}

_notify_detect_project() {
  local root="" code=""
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    root="$CLAUDE_PROJECT_DIR"
  else
    root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
    case "$root" in
      */.worktrees/*) root="${root%%/.worktrees/*}" ;;
    esac
  fi
  if [ -n "$root" ]; then
    if command -v pt_code_for_path >/dev/null 2>&1; then
      code="$(pt_code_for_path "$root" 2>/dev/null)"
    fi
    printf '%s' "${code:-$(basename "$root")}"
    return 0
  fi
  case "$PWD" in
    "$HOME/dev/"*)
      local rest="${PWD#"$HOME"/dev/}"
      printf '%s' "${rest%%/*}"
      ;;
  esac
}

say_notify() {
  local project="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--project) project="${2:-}"; shift 2 ;;
      --) shift; args+=("$@"); break ;;
      *) args+=("$1"); shift ;;
    esac
  done

  local text="${args[*]:-}"
  [ -n "${text// /}" ] || return 0

  local pipe
  pipe="$(_notify_pipe)"
  if [ -z "$pipe" ]; then
    echo "say_notify: no notify pipe (\$HERALD unset or bin/notify.sh not executable)" >&2
    return 0
  fi

  [ -n "$project" ] || project="$(_notify_detect_project)"
  local timeout_s="${SAY_NOTIFY_TIMEOUT:-15}"
  local -a cmd=("$pipe")
  [ -n "$project" ] && cmd+=(-p "$project")
  cmd+=("$text")

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" "${cmd[@]}" >/dev/null 2>&1 || {
      echo "say_notify: pipe failed or exceeded ${timeout_s}s — notification dropped" >&2
      return 0
    }
  else
    "${cmd[@]}" >/dev/null 2>&1 || {
      echo "say_notify: pipe failed — notification dropped" >&2
      return 0
    }
  fi
  return 0
}
