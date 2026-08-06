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
for subcommand in status history mute unmute test voices brief; do
  rg -q "${subcommand}" "$PLUGIN/commands/notify.md"
done
rg -q 'notify voices --json' "$PLUGIN/commands/notify.md"
rg -q 'root#\\~/' "$PLUGIN/commands/notify.md"
if rg -q 'voices\.json' "$PLUGIN/commands/notify.md"; then
  echo "notify command parses voices.json directly" >&2
  exit 1
fi

CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_ENV_FILE="$TMP/session-env" \
  "$PLUGIN/hooks-handlers/session-start.sh" > "$TMP/context.json"
# The hook is PATH-only: cc selects the style natively, so injecting it as
# SessionStart additionalContext would duplicate the same ~100 lines per session.
[ ! -s "$TMP/context.json" ]
# The style stays shippable as a source asset for operators without a native style.
rg -q 'NON-NEGOTIABLE Closing Ritual' "$PLUGIN/output-styles/tts-summary.md"
zsh -c 'source "$1"; command -v say_notify' _ "$TMP/session-env" | \
  rg -q '/plugin/bin/say_notify$'
zsh -c 'source "$1"; command -v say_brief' _ "$TMP/session-env" | \
  rg -q '/plugin/bin/say_brief$'
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
HERALD="$TMP/herald" HERALD_TEST_CAPTURE="$TMP/capture" \
  "$PLUGIN/bin/say_notify" -p hs "cross-shell smoke"
[ "$(cat "$TMP/capture")" = "-p hs cross-shell smoke" ]

# say_brief reaches the same pipe, through the same adapter, under both shells.
HERALD="$TMP/herald" HERALD_TEST_CAPTURE="$TMP/capture" \
  bash -c 'source "$1"; say_brief -p hs "digest smoke"' _ "$PLUGIN/lib/notify.sh"
[ "$(cat "$TMP/capture")" = "-p hs digest smoke" ]
HERALD="$TMP/herald" HERALD_TEST_CAPTURE="$TMP/capture" \
  "$PLUGIN/bin/say_brief" -p hs "adapter digest smoke"
[ "$(cat "$TMP/capture")" = "-p hs adapter digest smoke" ]

# The whole point of say_brief is the raised bound, so assert it behaves rather
# than that the file contains a "60". A pipe slower than the ambient
# SAY_NOTIFY_TIMEOUT is dropped by say_notify and survives say_brief.
cat > "$TMP/herald/bin/notify.sh" <<'SLOW'
#!/usr/bin/env bash
sleep 2
printf '%s\n' "$*" > "$HERALD_TEST_CAPTURE"
exit 0
SLOW
chmod +x "$TMP/herald/bin/notify.sh"

rm -f "$TMP/capture"
HERALD="$TMP/herald" HERALD_TEST_CAPTURE="$TMP/capture" \
  bash -c 'SAY_NOTIFY_TIMEOUT=1; source "$1"; say_notify "slow"' _ "$PLUGIN/lib/notify.sh" 2>/dev/null
[ ! -f "$TMP/capture" ] || { echo "say_notify ignored its bound" >&2; exit 1; }

HERALD="$TMP/herald" HERALD_TEST_CAPTURE="$TMP/capture" \
  bash -c 'SAY_NOTIFY_TIMEOUT=1; SAY_BRIEF_TIMEOUT=10; source "$1"; say_brief -p hs "slow digest"
           [ "$SAY_NOTIFY_TIMEOUT" = "1" ] || { echo "say_brief leaked its bound" >&2; exit 1; }' \
  _ "$PLUGIN/lib/notify.sh"
[ "$(cat "$TMP/capture")" = "-p hs slow digest" ]

# Briefings are explicit-only: no hook in this repo may reach for say_brief.
if rg -q 'say_brief' "$PLUGIN/hooks-handlers" "$PLUGIN/hooks"; then
  echo "a hook calls say_brief — briefings are explicit-request only" >&2
  exit 1
fi
rg -q 'EXPLICIT REQUEST ONLY' "$PLUGIN/output-styles/tts-summary.md"
rg -q 'brief me' "$PLUGIN/output-styles/tts-summary.md"

echo "plugin package: manifests, command, hook context, and caller helpers passed"
