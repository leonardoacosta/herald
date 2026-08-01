# Proposal: One voice at a time — serialized playback on the host

## Change ID

`serial-playback`

## Depends on

Nothing. `deep-briefings` makes the defect louder but did not cause it; this is independent of
both and can land before or after.

## Base commits (STOP on drift)

- herald — `bin/notify.sh` REMOTE_DETACH block (the `nohup ... afplay` heredoc), HEAD at
  execution time

## Why

Leo, 2026-08-01, from live use: two notifications landing close together play over each
other, and the result is unintelligible.

The cause is in the delivery leg, not any caller. `bin/notify.sh`'s detached remote command
ships the audio, backgrounds `afplay`, and returns — nothing on the playback host takes a
turn. Two concurrent calls become two `afplay` processes, and CoreAudio mixes them, which is
correct behavior for an audio system and wrong behavior for speech. Every notify caller is
affected; nothing in the repo serializes playback today (`grep -n 'flock\|lock' bin/notify.sh`
returns only comment prose).

`deep-briefings` widened the window rather than opening it: the overlap risk scales with how
long the audio plays, and a briefing is ~60s where a ping is ~3s. Concurrent notification is
the normal case here, not the edge case — `pkg/notify/store.go`'s own `AppendRecord` comment
already says so ("two agents notifying at once is the normal case").

## What Changes

**A spool plus a single drainer on the playback host.** Delivery stops launching a player and
starts enqueuing:

- **Enqueue** — the remote command writes the audio into a spool directory under a
  lexically-ordered name (timestamp + random suffix, so arrival order is sort order), then
  attempts to become the drainer. It returns as soon as the bytes land, preserving today's
  detached timing and the `delivered` record's meaning.
- **Drain** — exactly one drainer runs at a time, elected by an atomic `mkdir` lock (macOS
  ships no `flock(1)`). It plays the oldest spooled clip, deletes it, and repeats until the
  spool is empty, then releases the lock. A clip arriving mid-playback is simply the next file
  the loop picks up, so the stream continues into it rather than over it.
- **Exit race** — a clip enqueued in the window between "spool looks empty" and "lock
  released" would otherwise sit unplayed until the next notify. The drainer re-checks the
  spool after releasing and re-acquires if anything appeared.
- **Staleness** — a drainer killed mid-clip must not leave a lock that mutes the host forever.
  The lock carries its owner's pid; an acquirer that finds a lock whose owner is gone breaks
  it. **Silence is the worse failure**: every ambiguous case resolves toward playing.

**What this deliberately does not do:** it does not splice into audio already in flight.
`afplay` has the file open and will not observe appended bytes, so "include the new update in
the current stream" means gapless *succession*, not mid-sentence insertion. True splicing
needs a streaming player and is out of scope (and already excluded by `deep-briefings`'
non-goals).

**Recorded outcome is unchanged.** `delivered` continues to mean "the bytes reached the
playback host", which is all the pipe could ever attest to — it never waited for audio in the
detached form. No new value enters `store.go`'s closed outcome set. This is the whole reason
queueing was chosen over dropping: a `playback_busy` outcome would have forced that set open.

## Non-goals / out of scope

- No streaming or interruptible playback; no mid-clip splicing.
- No priority lane — a briefing does not jump ahead of a ping, or vice versa. Arrival order
  is the whole policy. If that proves wrong in use, it is a follow-on with real evidence.
- No spool persistence across reboots; unplayed audio on a rebooted host is discarded.
- No change to `--wait`, which already blocks through playback and is used only for evidence
  capture. It enqueues like everything else and waits for its own clip to finish.

## Exemplars

- Atomic election and the trap discipline it must preserve: the existing `REMOTE_DETACH`
  heredoc in `bin/notify.sh:185-191`, whose comment block documents why `ssh -n` is banned and
  why the trap is cleared only after the bytes land. Both constraints survive this change.
- Bounded, fail-soft shell under a lock: `plugin/commands/notify.md`'s `mute` branch —
  `mktemp` + `mv` for an atomic replace, never an in-place edit.

## Definition of Done

- **Mechanical**: a test fires N notifications concurrently and asserts that at no point do
  two `afplay` processes for herald spool files coexist, and that all N clips play. A test
  that kills a drainer mid-clip asserts the next notify still plays (lock was broken, not
  inherited).
- **Behavior**: two `say_notify` calls issued back to back are heard one after the other, in
  order, with no overlap — Leo confirms by ear.
- **Done-when**: proposal archived; the spool contract documented in `AGENTS.md` ground rules
  alongside the fail-soft and single-speech-path entries.

## STOP conditions

- Any design where a leaked or stale lock can silently suppress playback with no bounded
  recovery — report it rather than shipping it. Overlapping speech is a nuisance; a silent
  notifier is a broken contract.
- Serialization measurably delaying a lone notification (the uncontended path must not get
  slower) — report the measurement instead of accepting the regression.
