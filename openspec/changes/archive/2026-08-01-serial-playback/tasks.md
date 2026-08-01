# Tasks — serial-playback

## 1. Reproduce

- [x] 1.1 Capture the defect before changing anything: fire two notifications ~1s apart and
      record that two `afplay` processes coexist on the playback host. Verify: process
      snapshot showing both, attached to the proposal.

## 2. Spool and drainer

- [x] 2.1 Replace `REMOTE_DETACH` in `bin/notify.sh` with the enqueue form: write the audio
      into the spool under a sort-ordered name, then attempt drainer election. Preserve the
      existing constraints — no `ssh -n`, trap cleared only after the bytes land. Verify:
      a single notification still plays and still records `delivered`.
- [x] 2.2 Implement the drainer loop: play oldest-first, delete each clip after it plays,
      exit when the spool is empty, then re-check and re-acquire if a clip arrived during
      release. Verify: shell test — N clips enqueued during playback all play, in order.
- [x] 2.3 Lock staleness: an acquirer finding a lock whose owner pid is gone breaks it.
      Verify: kill a drainer mid-clip, fire again, assert audio plays and no lock survives.

## 3. Guard the regression

- [x] 3.1 Concurrency test asserting no two herald `afplay` processes ever coexist under a
      burst of N concurrent notifications, and that all N clips play. Verify: test passes,
      and fails against the pre-change `REMOTE_DETACH`.
- [x] 3.2 Uncontended latency check: a lone notification is no slower than before. Verify:
      before/after timings on the same text. STOP if serialization costs the common path.

## 4. Doctrine

- [x] 4.1 Add the spool/one-voice-at-a-time contract to `AGENTS.md` ground rules beside the
      fail-soft and single-speech-path entries. Verify: rule present and names the
      silence-is-worse tiebreak.

## 5. Evidence

- [x] 5.1 Two back-to-back `say_notify` calls heard in order with no overlap — Leo confirms
      by ear before archive. Confirmed 2026-08-01: in order, no overlap, one player where
      there were two. Leo also reported an audible pause between clips; batching removed it
      for simultaneous arrivals, and the residual on sequential calls was measured to be
      CoreAudio device-open latency (see proposal § Measured), accepted here and routed to a
      follow-on resident-player proposal.
