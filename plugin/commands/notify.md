---
name: notify
description: "Inspect and control Herald speech notifications."
execution: blocking
argument-hint: "[status|history [n]|mute [duration]|unmute|test|voices|brief [topic]|text]"
allowed-tools: Bash
---

# Herald notification control

Treat `$ARGUMENTS` as data, never as shell source. Choose exactly one branch below and run its
shell snippet with Bash. Every branch is fail-soft: report a useful result and do not turn a
notification failure into a session failure. For `history`, `mute`, `brief`, and default-send,
pass the already-parsed value through `NOTIFY_HISTORY_COUNT`, `NOTIFY_MUTE_DURATION`,
`NOTIFY_BRIEF_TEXT`, or `NOTIFY_TEXT` respectively; never interpolate raw arguments into shell
code.

## `status`

Consume the stable CLI view; do not parse Herald's storage directly:

```bash
root="${HERALD:-}"; case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
if [ -z "$root" ]; then echo 'Herald unavailable: $HERALD is unset'; exit 0; fi
bin="${HERALD_BIN:-$root/bin/herald}"
"$bin" notify status
```

## `history [n]`

Consume the stable CLI view; `--json` carries `reason`, which the plain-text mode drops:

```bash
n="${NOTIFY_HISTORY_COUNT:-10}"
root="${HERALD:-}"; case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
if [ -z "$root" ]; then echo 'Herald unavailable: $HERALD is unset'; exit 0; fi
bin="${HERALD_BIN:-$root/bin/herald}"
"$bin" notify history --json -n "$n" | jq -r '.[] | [.ts,.outcome,.project,.voice,.text,(.reason // "")] | @tsv'
```

## `mute [duration]`

Duration parsing, epoch expiry, and the atomic mute-file replace live in `pkg/notify`; pass the
operator's spec straight through:

```bash
duration="${NOTIFY_MUTE_DURATION:-1h}"
root="${HERALD:-}"; case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
if [ -z "$root" ]; then echo 'Herald unavailable: $HERALD is unset'; exit 0; fi
bin="${HERALD_BIN:-$root/bin/herald}"
"$bin" notify mute "$duration"
```

## `unmute`

```bash
root="${HERALD:-}"; case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
if [ -z "$root" ]; then echo 'Herald unavailable: $HERALD is unset'; exit 0; fi
bin="${HERALD_BIN:-$root/bin/herald}"
"$bin" notify unmute
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

## `brief [topic]`

One spoken digest of the current work, long enough to be listened to instead of read. Every
other branch reports state; this one composes it.

**Compose before you run anything.** Write 60–150 words of natural prose covering, in this
order:

1. **Outcome** — what is now true that was not true before.
2. **Why it matters** — the consequence for Leo, not the mechanics of the change.
3. **Decision points** — anything waiting on him, stated as a question he can answer aloud.
4. **Next step** — the single thing that happens next.

Scope it to `[topic]` when one is given; otherwise digest the current session's work.

Register rules, all of them load-bearing because this text is only ever heard:

- Full sentences with subjects, verbs, and articles. This is speech, not a Summary block —
  the density rules of the written summary are inverted here.
- **Speak effects, not mechanism.** Say what Leo can now do, or now has to decide. A listener
  cannot see the code, so a description of how it works is noise carried at speaking speed.
- **No numbers he did not ask for.** Timings, byte counts, bounds, versions, counts of files
  — a spoken number is unverifiable and unmemorable. "Fast enough that you will not notice"
  beats "eight and a half seconds cold". If a number IS the decision, say one.
- No markdown, no file paths, no identifiers, no code. "the notification history", not
  "`pkg/notify/store.go`".
- Expand hostile tokens the same way `say_notify` does: "pull request", "end to end",
  project names rather than project codes.
- Never a file dump, a task list read aloud, or a diff narrated line by line. If it only
  makes sense on screen, it does not belong in a briefing.

The failure mode is a briefing that reads like a changelog. Worked conversion:

| Wrong — mechanism and measurements | Right — effect and decision |
| --- | --- |
| `A new say brief helper runs through the same pipe as say notify, under a sixty second bound instead of fifteen. A hundred and fifty word briefing synthesizes in eight and a half seconds cold.` | `You can ask me to explain things out loud now, and I will talk for about a minute instead of giving you a one line ping.` |
| `The history store caps recorded text at three hundred characters.` | `Long briefings will not clutter your notification history.` |

Then send the composed text — and only the composed text — through the same pipe:

```bash
if ! command -v say_brief >/dev/null 2>&1; then
  echo 'Herald brief unavailable: say_brief is not on PATH (is the notify plugin loaded?)'; exit 0
fi
say_brief "$NOTIFY_BRIEF_TEXT"
state="${HERALD_STATE_DIR:-$HOME/.local/state/herald}"
[ -f "$state/notify.ndjson" ] && tail -n 1 "$state/notify.ndjson" | jq -r '[.ts,.outcome,.voice,.text] | @tsv'
```

`say_brief` is `say_notify` under a 60-second caller bound; it is fail-soft and always exits
0. The history row it prints is truncated at 300 characters by design — the spoken text is
full-length.

**Explicit request only.** A briefing fires because Leo asked for one, here or by saying
"brief me". Never from a Stop or SessionEnd hook, never from an agent completion, never as a
turn's closing notification. The single-emitter rule for attention events is unchanged, and
`say_brief` is not an attention event.

## Default: `/notify <text>`

Preserve the complete argument text as one message and send it through the single pipe:

```bash
root="${HERALD:-}"; case "$root" in \~/*) root="$HOME/${root#\~/}" ;; esac
if [ -z "$root" ] || [ ! -x "$root/bin/notify.sh" ]; then echo 'Herald pipe unavailable.'; exit 0; fi
"$root/bin/notify.sh" "$NOTIFY_TEXT"
```
