---
name: notify
description: "Inspect and control Herald speech notifications."
execution: blocking
argument-hint: "[status|history [n]|mute [duration]|unmute|test|voices|text]"
allowed-tools: Bash
---

# Herald notification control

Treat `$ARGUMENTS` as data, never as shell source. Choose exactly one branch below and run its
shell snippet with Bash. Every branch is fail-soft: report a useful result and do not turn a
notification failure into a session failure. For `history`, `mute`, and default-send, pass the
already-parsed value through `NOTIFY_HISTORY_COUNT`, `NOTIFY_MUTE_DURATION`, or `NOTIFY_TEXT`
respectively; never interpolate raw arguments into shell code.

## `status`

Verify `$HERALD`, its executable pipe and binary, the shared mute state, and the configured
Kokoro health URL:

```bash
root="${HERALD:-}"
if [ -z "$root" ]; then echo 'Herald unavailable: $HERALD is unset'; exit 0; fi
case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
pipe="$root/bin/notify.sh"
bin="${HERALD_BIN:-$root/bin/herald}"
state="${HERALD_STATE_DIR:-$HOME/.local/state/herald}"
base="${HERALD_KOKORO_BASE_URL:-${NOTIFY_KOKORO_BASE_URL:-}}"
printf 'HERALD: %s\npipe: %s\nbinary: %s\n' "$root" "$([ -x "$pipe" ] && echo ready || echo missing)" "$([ -x "$bin" ] && echo ready || echo missing)"
if [ -f "$state/mute" ]; then printf 'mute expiry: %s\n' "$(head -n 1 "$state/mute")"; else echo 'mute: off'; fi
if [ -n "$base" ]; then printf 'Kokoro health: %s/health\n' "${base%/}"; else echo 'Kokoro health: notify pipe default'; fi
```

## `history [n]`

Validate `n` as an integer from 1 through 100 (default 10), then render the tail without
changing it:

```bash
n="${NOTIFY_HISTORY_COUNT:-10}"
state="${HERALD_STATE_DIR:-$HOME/.local/state/herald}"
history="$state/notify.ndjson"
if [ ! -f "$history" ]; then echo 'No Herald notification history yet.'; exit 0; fi
tail -n "$n" "$history" | jq -r '[.ts,.outcome,.project,.voice,.text,(.reason // "")] | @tsv'
```

## `mute [duration]`

Accept `s`, `m`, `h`, or `d` suffixes (default `1h`), compute an epoch expiry without `eval`,
and atomically replace the shared mute file:

```bash
duration="${NOTIFY_MUTE_DURATION:-1h}"
case "$duration" in
  *s) multiplier=1; amount="${duration%s}" ;;
  *m) multiplier=60; amount="${duration%m}" ;;
  *h) multiplier=3600; amount="${duration%h}" ;;
  *d) multiplier=86400; amount="${duration%d}" ;;
  *) echo 'Duration must end in s, m, h, or d.'; exit 0 ;;
esac
case "$amount" in ''|*[!0-9]*) echo 'Duration must use a positive integer.'; exit 0 ;; esac
state="${HERALD_STATE_DIR:-$HOME/.local/state/herald}"
umask 077; mkdir -p "$state"
tmp="$(mktemp "$state/.mute.XXXXXX")" || exit 0
printf '%s\n' "$(( $(date +%s) + amount * multiplier ))" > "$tmp" && mv "$tmp" "$state/mute"
echo "Herald muted for $duration."
```

## `unmute`

```bash
state="${HERALD_STATE_DIR:-$HOME/.local/state/herald}"
rm -f -- "$state/mute"
echo 'Herald unmuted.'
```

## `test`

Run a fixed, blocking round trip and print only the record it created:

```bash
root="${HERALD:-}"; case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
if [ -z "$root" ] || [ ! -x "$root/bin/notify.sh" ]; then echo 'Herald pipe unavailable.'; exit 0; fi
state="${HERALD_STATE_DIR:-$HOME/.local/state/herald}"
"$root/bin/notify.sh" --wait 'Herald notification test completed.'
[ -f "$state/notify.ndjson" ] && tail -n 1 "$state/notify.ndjson" | jq .
```

## `voices`

Consume the stable CLI view; do not parse Herald's storage directly:

```bash
root="${HERALD:-}"; case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
if [ -z "$root" ]; then echo 'Herald unavailable: $HERALD is unset'; exit 0; fi
bin="${HERALD_BIN:-$root/bin/herald}"
"$bin" notify voices --json | jq -r '.[] | [.project,.stored,.effective,.source,(.speed // 0)] | @tsv'
```

## Default: `/notify <text>`

Preserve the complete argument text as one message and send it through the single pipe:

```bash
root="${HERALD:-}"; case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
if [ -z "$root" ] || [ ! -x "$root/bin/notify.sh" ]; then echo 'Herald pipe unavailable.'; exit 0; fi
"$root/bin/notify.sh" "$NOTIFY_TEXT"
```
