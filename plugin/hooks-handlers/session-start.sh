#!/usr/bin/env bash
# Puts the plugin's cross-shell notify adapter on PATH for every tool shell.
#
# This hook no longer injects output-styles/tts-summary.md as SessionStart
# additional context. Claude Code plugins still cannot load output-style
# directories, so that injection was a bridge for operators with no native
# style; cc now selects the style natively (settings.json "outputStyle":
# "TTS Summary" -> cc output-styles/tts-summary.md) and the bridge only
# duplicated ~100 lines of identical context per session. The plugin copy
# remains the portable source asset for operators who want to install it.
set +e

# Claude's Bash tool may use the operator's login shell (zsh here), so BASH_ENV
# alone cannot make a shell function portable. SessionStart's documented env
# seam puts the plugin's thin adapter on PATH for every tool shell; the adapter
# still delegates to the one say_notify function in lib/notify.sh.
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  plugin_bin="${CLAUDE_PLUGIN_ROOT%/}/bin"
  escaped_bin="${plugin_bin//\'/\'\\\'\'}"
  # Keep $PATH dynamic in Claude's session env file.
  # shellcheck disable=SC2016
  printf 'export PATH='"'"'%s'"'"':"$PATH"\n' "$escaped_bin" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

exit 0
