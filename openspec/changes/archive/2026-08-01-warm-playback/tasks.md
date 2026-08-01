# Tasks — warm-playback

## 1. Decide the shape

- [x] 1.1 Measure the floor before building: with the audio device held open by a trivial
      resident process, how long from clip-available to first sample? Verify: measured
      number beside today's 760-1533ms. STOP if the gain is not real.
- [x] 1.2 Implement the `launchd` user agent per the decision below: a plist installed on the
      playback host, `KeepAlive` on crash, started at login. Verify: agent survives a kill and
      a reboot; `launchctl list` shows it.

## 2. The resident player

- [x] 2.1 Implement the player: holds an open output stream, watches the spool, plays clips
      oldest-first, deletes each after playing. Reuses the existing lock so it and the
      fallback drainer can never both play. Verify: clips enqueued while it runs play in
      order with no second player.
- [x] 2.2 Idle release: after a configurable idle window the device is released and
      reacquired on the next clip. Verify: device shown released after the window, and the
      next clip still plays. Verified behaviorally with `HERALD_PLAYER_IDLE=5` in an isolated
      spool — the decoder exits after the window and the next clip plays. KNOWN GAP: the
      "releasing the audio device" log line does not appear on that path and I could not
      account for it; the behaviour is right, the observability is not.
- [x] 2.3 Install/start path per the 1.2 decision, including reinstall being idempotent.
      Verify: fresh start from absent, then a second start is a no-op.

## 3. Fallback

- [x] 3.1 Absent or wedged daemon falls back to the current drainer. Verify: kill the daemon
      mid-queue, fire again, audio still plays and the spool drains.
- [x] 3.2 Regression test asserting the two never play concurrently. Verify: test passes,
      and fails if the daemon ignores the lock.

## 4. Doctrine

- [x] 4.1 Document the daemon's lifecycle, idle policy, and the fallback guarantee in
      `AGENTS.md` beside the one-voice-at-a-time rule. Verify: rule present.

## 5. Evidence

- [x] 5.1 Two sequential `say_notify` calls a few seconds apart, no audible pause before
      either — Leo confirms by ear before archive. Confirmed 2026-08-01 with the player warm:
      the pause is gone. Caveat recorded in the proposal: the FIRST clip after a cold start
      (or after the idle window releases the device) still pays ~850ms to wake it.
