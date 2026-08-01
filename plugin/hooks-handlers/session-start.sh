#!/usr/bin/env bash
# Fail-soft bridge for the former TTS Summary output style. Claude Code plugins
# do not load output-style directories, so inject the plugin-owned source asset
# as SessionStart additional context.
set +e

style="${CLAUDE_PLUGIN_ROOT:-}/output-styles/tts-summary.md"
[ -r "$style" ] || exit 0

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
