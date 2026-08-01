#!/usr/bin/env bash
# Minimal read-only projects.toml seam used by the Herald caller helper.
# Sourceable: never leaks strict mode into a hook or interactive shell.

[[ -n "${_HERALD_PROJECTS_TOML_LOADED:-}" ]] && return 0
_HERALD_PROJECTS_TOML_LOADED=1

PROJECTS_TOML_PATH="${PROJECTS_TOML_PATH:-${HERALD_PROJECTS_TOML:-$HOME/dev/personal/installfest/home/projects.toml}}"
PROJECTS_TOML_HOME_BASE="${PROJECTS_TOML_HOME_BASE:-$HOME}"

_pt_python() {
  local candidate
  for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

pt_code_for_path() {
  local abspath="${1:-}" py
  [ -n "$abspath" ] && [ -f "$PROJECTS_TOML_PATH" ] || return 0
  py="$(_pt_python)" || return 0
  "$py" -c '
import os, sys, tomllib

target, toml_path, home_base = sys.argv[1:]
try:
    with open(toml_path, "rb") as stream:
        projects = tomllib.load(stream).get("projects", [])
except Exception:
    raise SystemExit(0)
target = os.path.normpath(target)
for project in projects:
    relative = project.get("path")
    if relative and os.path.normpath(os.path.join(home_base, relative)) == target:
        print(project.get("code", ""))
        break
' "$abspath" "$PROJECTS_TOML_PATH" "$PROJECTS_TOML_HOME_BASE" 2>/dev/null
}
