# Proposal: Hold the audio device open so speech starts instantly

## Change ID

`warm-playback`

## Depends on

`serial-playback` — this replaces what that change's drainer does with the audio, and keeps
its spool, its lock, and its ordering guarantees unchanged.

## Base commits (STOP on drift)

- herald — `bin/notify.sh` REMOTE_SPOOL block, HEAD at execution time

## Why

Leo, 2026-08-01, after `serial-playback` landed: notifications no longer overlap, but there
is an audible pause before each one starts.

Measured on the playback host against 1824ms of audio: `afplay` +760/+1264ms, `mpg123`
+570/+1355ms, `ffplay` +750/+1533ms. Three unrelated players land in the same band, so the
cost is CoreAudio opening the output device (Studio Display speakers), not the player. No
choice of player fixes it.

`serial-playback` removed it for clips that arrive together — a batch shares one device open.
It cannot reach the common case: two sequential notify calls are separated by synthesis
(~3s), the device closes in between, and the next playback pays the open cost again.

The only way to stop paying it is to stop closing the device. That means something on the Mac
that outlives a single clip.

## What Changes

**A resident player on the playback host**, owning the audio device and consuming the
existing spool:

- **Lifecycle** — a long-lived process supervised by a `launchd` user agent, holding an open
  output stream so a clip begins immediately. It restarts on crash and starts at login, so
  the warm path is the normal state rather than something the first notification has to
  establish.
- **Idle policy** — the reason afplay is cheap to be wrong about is that it holds nothing. A
  resident stream is a real cost (device held, other apps see it in use). It SHALL release
  the device after a configurable idle window and reacquire on the next clip, trading the
  pause back only when nothing has been spoken for a while.
- **Delivery unchanged** — `bin/notify.sh` keeps enqueuing into the spool exactly as it does
  now. The remote command SHALL NOT learn about the daemon beyond ensuring one is running;
  ordering, batching, and the `delivered` record all keep their current meaning.
- **Fallback is mandatory** — if the daemon is absent, wedged, or fails to start, delivery
  falls back to the current drainer. A notification MUST NOT depend on a daemon being
  healthy. This is the whole reason the spool stays the interface.

## Non-goals / out of scope

- No change to synthesis, voice resolution, history, or the outcome set.
- No streaming or mid-clip splicing (still excluded, as in `deep-briefings`).
- No priority lane or interruption — arrival order remains the entire policy.
- Not a general audio service: it plays herald spool clips and nothing else.

## Exemplars

- Spool contract, lock election, and staleness handling to reuse verbatim: the REMOTE_SPOOL
  block in `bin/notify.sh` and its comment block.
- Fail-soft posture when a dependency is missing: `bin/notify.sh`'s
  `record_unavailable_binary` — degrade to a recorded outcome, never propagate an error.

## Definition of Done

- **Mechanical**: measured time from clip-enqueued to first audio sample, with the daemon
  warm, is under 150ms — against the 760-1533ms measured today. Same measurement with the
  daemon killed shows the fallback still plays.
- **Behavior**: two sequential `say_notify` calls a few seconds apart have no audible pause
  before either — Leo confirms by ear.
- **Done-when**: proposal archived; the daemon's lifecycle and idle policy documented in
  `AGENTS.md` beside the one-voice-at-a-time rule.

## STOP conditions

- The daemon holding the device open interferes with any other audio on the Mac (music
  ducking, device shown busy, input/output routing changes) — report it; a notifier that
  degrades everyday audio is not worth a saved second.
- A daemon failure mode that can silence notifications rather than fall back — the
  silence-is-worse tiebreak from `serial-playback` is inherited and non-negotiable.
- Measured warm start-up not actually beating the current numbers — report the measurement
  rather than shipping a daemon that bought nothing.

## Decisions

- **Supervisor: `launchd` user agent.** decided-by: leo, 2026-08-01. Chosen over a
  self-respawning process started by the spool script. The one-time plist install is a real
  new setup step for the playback host, and it buys the property that matters: the warm path
  survives reboot and logout, so the device is already open for the first notification of the
  day rather than that one paying the old cost. Crash restart comes free with `KeepAlive`.
