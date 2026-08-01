#!/usr/bin/env bash
# Fail-soft bridge for the former TTS Summary output style. Claude Code plugins
# do not load output-style directories, so inject the plugin-owned source asset
# as SessionStart additional context.
set +e

style="${CLAUDE_PLUGIN_ROOT:-}/output-styles/tts-summary.md"
[ -r "$style" ] || exit 0

# Claude's Bash tool may use the operator's login shell (zsh here), so BASH_ENV
# alone cannot make a shell function portable. SessionStart's documented env
# seam puts the plugin's thin adapter on PATH for every tool shell; the adapter
# still delegates to the one say_notify function below.
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  plugin_bin="${CLAUDE_PLUGIN_ROOT%/}/bin"
  escaped_bin="${plugin_bin//\'/\'\\\'\'}"
  # Keep $PATH dynamic in Claude's session env file.
  # shellcheck disable=SC2016
  printf 'export PATH='"'"'%s'"'"':"$PATH"\n' "$escaped_bin" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

if command -v jq >/dev/null 2>&1; then
  jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}' < "$style" 2>/dev/null || true
elif command -v python3 >/dev/null 2>&1; then
  python3 - "$style" <<'PY' 2>/dev/null || true
import json
import pathlib
import sys

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": pathlib.Path(sys.argv[1]).read_text(),
    }
}))
PY
fi

exit 0
