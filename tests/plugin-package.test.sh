#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$REPO/plugin"
TMP="$(mktemp -d -t herald-plugin.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

jq -e '.name == "notify" and .version and .description' \
  "$PLUGIN/.claude-plugin/plugin.json" >/dev/null
jq -e '.name == "herald" and any(.plugins[]; .name == "notify" and .source == "./")' \
  "$PLUGIN/.claude-plugin/marketplace.json" >/dev/null
jq -e '.hooks.SessionStart[0].hooks[0].command | contains("${CLAUDE_PLUGIN_ROOT}/hooks-handlers/session-start.sh")' \
  "$PLUGIN/hooks/hooks.json" >/dev/null

rg -q '^name: notify$' "$PLUGIN/commands/notify.md"
rg -q '^execution: blocking$' "$PLUGIN/commands/notify.md"
for subcommand in status history mute unmute test voices; do
  rg -q "${subcommand}" "$PLUGIN/commands/notify.md"
done
rg -q 'notify voices --json' "$PLUGIN/commands/notify.md"
if rg -q 'voices\.json' "$PLUGIN/commands/notify.md"; then
  echo "notify command parses voices.json directly" >&2
  exit 1
fi

CLAUDE_PLUGIN_ROOT="$PLUGIN" "$PLUGIN/hooks-handlers/session-start.sh" > "$TMP/context.json"
jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and
  (.hookSpecificOutput.additionalContext | contains("NON-NEGOTIABLE Closing Ritual"))' \
  "$TMP/context.json" >/dev/null
CLAUDE_PLUGIN_ROOT="$TMP/missing" "$PLUGIN/hooks-handlers/session-start.sh" >/dev/null

mkdir -p "$TMP/herald/bin"
cat > "$TMP/herald/bin/notify.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HERALD_TEST_CAPTURE"
exit 0
FAKE
chmod +x "$TMP/herald/bin/notify.sh"
HERALD="$TMP/herald" HERALD_TEST_CAPTURE="$TMP/capture" \
  bash -c 'source "$1"; say_notify -p hs "plugin smoke"' _ "$PLUGIN/lib/notify.sh"
[ "$(cat "$TMP/capture")" = "-p hs plugin smoke" ]

echo "plugin package: manifests, command, hook context, and caller helper passed"
