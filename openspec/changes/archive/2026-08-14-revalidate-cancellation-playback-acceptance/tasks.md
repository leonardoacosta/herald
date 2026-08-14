# Tasks: revalidate-cancellation-playback-acceptance

## 1. Preconditions and alignment gate

- [x] 1.1 Implement gate 0: service health, running-vs-on-disk version comparison
      (reusing `bin/service-sync.sh`'s `version_of` semantics), shared-config digest and
      divergence check, playback-host reachability, resident-player lock readability.
  - Verify: with the deployed system healthy, gate 0 passes and emits the alignment
    section; with an induced stale-binary override, it fails before any audio.
- [x] 1.2 Implement `--live` gating: without the flag only gate 0 and the HTTP
      contract spot-checks (matrix row 9) run.
  - Verify: a non-live run produces a report and plays no audio (no spool entries, no
    delivered history rows attributable to the run nonce).

## 2. Harness and evidence report

- [x] 2.1 Create the acceptance runner under `tests/` with per-call timeouts, run
      nonce, trap-based cleanup (unmute, remove own spool debris), and `--out` support.
  - Verify: `bash -n` clean; a failing mid-run invocation still writes a report and
    leaves mute off.
- [x] 2.2 Implement the evidence report writer: alignment section, per-row records
      (request ID, transport, raw responses, history rows, boundary evidence), and the
      closed verdict `pass|fail|partial`.
  - Verify: report validates against a documented shape (jq assertions in a small
    self-test), contains no secret values.
- [x] 2.3 Implement read-only playback-boundary evidence collection: spool listing
      before/after, lock holder, per-clip served-by mode, player log tail when present.
  - Verify: collection performs no writes on the playback host besides reads over the
    existing SSH identity.

## 3. Test matrix rows

- [x] 3.1 Rows 1-2: service-path notify and `--wait` local path, each proving one
      terminal history row and single delivery.
- [x] 3.2 Row 3: queued cancellation with no synthesis/delivery evidence.
- [x] 3.3 Rows 4-5: active-playback cancellation and unrelated-clip survival,
      matching stop-response `stopped` against boundary evidence.
- [x] 3.4 Row 6: stop idempotency and unknown-ID no-op, asserting zero new history
      rows.
- [x] 3.5 Row 7: two-clip serialization, order preserved, both delivered.
- [x] 3.6 Row 8: mute round-trip with guaranteed unmute cleanup.
- [x] 3.7 Row 9: raw HTTP contract spot-checks for `/notify` and `/notify/stop`
      (accepted, malformed `400`, unknown-ID no-op shape).
  - Verify (all of §3): each row records expected vs observed and maps every accepted
    request ID to exactly one terminal history row.

## 4. Documentation

- [x] 4.1 Document the acceptance protocol, blockers, `--live` authorization
      requirement, and report location in `docs/` (or the tests README convention this
      repo uses), including the "partial vs pass" verdict semantics.
  - Verify: a fresh operator can run the harness from the doc alone.

## 5. Acceptance

- [x] 5.1 Run two authorized `--live` acceptance runs against the deployed service and Mac playback host; archive both report files as evidence.
  - Done: `/home/nyaptor/.local/state/herald/acceptance/authorized-20260814-1.json` and
    `/home/nyaptor/.local/state/herald/acceptance/authorized-20260814-2.json` both returned
    `verdict: pass`, `live: true`, `exit_code: 0`, `not_exercised: []`, and all nine rows passed.
    Durations were 59s and 45s, under the three-minute bound.
- [x] 5.2 Induce a version mismatch non-destructively and confirm gate 0 aborts with
      the documented message and no audio, then restore.
  - Done: `tests/acceptance-cancellation.test.sh` § 3 does exactly this via
    `HERALD_ACCEPTANCE_BIN` pointed at a stale-reporting stub. Nothing deployed is
    touched, so there is nothing to restore.
- [x] 5.3 Run the existing shell and Go test suites to confirm the harness introduced
      no regressions, then close out per the OpenSpec workflow (approval, commit,
      archive are outside this drafting task).
