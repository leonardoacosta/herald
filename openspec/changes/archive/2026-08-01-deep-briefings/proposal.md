# Proposal: Deep spoken briefings on demand

## Change ID

`deep-briefings`

## Depends on

`extract-notify-pipeline`; pairs with `herald-cc-plugin` (the trigger ships in the plugin's
command + output style). `voice-quality` is not a blocker but makes briefs pleasant.

## Base commits (STOP on drift)

- cc `c820c42d` — tts-summary output style, `SAY_NOTIFY_TIMEOUT` in
  `scripts/lib/notify.sh:127`
- herald — HEAD at execution time

## Why

Advisor run 2026-07-31, Leo's explicit ask: every spoken call site today is a <20-word
ping (the tts-summary style caps the `say_notify` line, cc `output-styles/tts-summary.md:47`).
There is no path to a longer spoken explanation — "what just happened, why, what's next" —
without reading the screen. The pipe already supports it: detached playback
(`bin/notify.sh` REMOTE_DETACH) returns as soon as bytes land, so long audio never holds a
hook; Kokoro-FastAPI auto-stitches long input. The binding constraint is the caller-side
`SAY_NOTIFY_TIMEOUT` (15s) and synthesis bound (30s), sized for one-liners.

## What Changes

- **`say_brief`** in the plugin lib (sibling of `say_notify`, same file): identical
  contract (exit 0, project detection) with `SAY_NOTIFY_TIMEOUT` default raised to 60 for
  this path and a `--wait`-less detached send. Long text is the normal case.
- **`/notify brief [topic]`** subcommand (extends `herald-cc-plugin`'s command): Claude
  composes a 60–150-word natural-prose digest of the current session/work — outcome, why
  it matters, decision points, next step — then calls `say_brief`. Composition rules live
  in the command body: spoken register (full sentences, no markdown artifacts, jargon
  expanded per `voice-quality`), never a file dump.
- **Output-style trigger**: tts-summary gains one rule — when Leo says "brief me",
  "explain out loud", or similar, compose and fire a `say_brief` digest for that turn.
  **Explicit-only**: never auto-fired from Stop/SessionEnd hooks or agent completions;
  the existing single-emitter rule for attention events is untouched.
- **History**: brief attempts record like any other (text truncated to the store's
  existing limits if any; verify `store.go` behavior for long text — if it stores
  verbatim, cap the recorded text at ~300 chars with an ellipsis, keeping the spoken text
  full-length).

## Measured timings (task 1.1, 2026-08-01)

Deployed Kokoro (`ghcr.io/remsky/kokoro-fastapi-cpu:v0.6.0`, loopback), voice
`kokoro:af_heart+af_bella(3)` at speed 0.95. Cold = first synthesis after `docker restart
kokoro` (healthy after 8s); warm = steady state. `herald notify synth`, wall clock:

| Words | Cold  | Warm  | Audio    |
| ----- | ----- | ----- | -------- |
| 60    | 3.54s | 2.45s | 408 KB   |
| 100   | 5.89s | 5.07s | 629 KB   |
| 150   | 8.49s | 7.05s | 927 KB   |

No STOP: 150 words cold is 8.5s against the 60s threshold. Delivery is not the constraint
either — 927 KB transfers to the playback host in 0.11s over the tailnet.

**What this changed in the design.** Synthesis fits inside the pipe's existing 30s bound with
3.5x headroom, so that bound is left alone and `say_brief` raises only the caller-side one.
The 15s caller bound was still wrong, but not for the stated reason: 8.5s of synthesis plus a
sleeping playback host's full 10s delivery timeout is 18.5s, and under 15s `timeout(1)` kills
the pipe *before* it can append its `transport_timeout` record. The raise to 60s exists to
keep that failure observable, not to make room for synthesis.

## Non-goals / out of scope

- No streaming/interruptible playback, no conversation — one-shot digest only.
- No auto-briefing schedule.
- No second speech function beyond `say_brief` (the single-speech-path rule holds; both
  functions share the same pipe and file).

## Exemplars

- Helper shape + fail-soft: `say_notify` itself (plugin lib `notify.sh`, formerly cc
  `scripts/lib/notify.sh:105-144`) — `say_brief` is a ~10-line variant, not a fork.
- Command subcommand structure: `/notify test` in `herald-cc-plugin`'s command file.
- Register rules for the digest: the speakable-text rule + examples added by
  `voice-quality` task 3.1.

## Definition of Done

- **Mechanical**: shell test — `say_brief` with 150 words of text exits 0 in <60s with
  Kokoro up, and exits 0 fast with it down (`synth_failed` recorded); grep confirms no
  new call sites in hooks (`grep -rn say_brief scripts/hooks/` in cc is empty).
- **Behavior**: "brief me" in a live session produces one spoken digest of that session's
  work, audibly complete (evidence: history record + Leo confirmation).
- **Done-when**: proposal archived; `/notify brief` documented in the command file;
  output-style trigger present with the explicit-only warning.

## STOP conditions

- Cold-CPU synthesis of a 150-word digest exceeds 60s in testing — report measured
  timings and propose the bound, don't silently raise it.
- Any implementation pressure to auto-fire briefs from hooks — that contradicts the
  explicit-only requirement; report instead.
