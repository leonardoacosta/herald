# Tasks — interruptible-playback-control

## 1. Lifecycle and request identity

- [ ] 1.1 Define the request model and closed lifecycle states: accepted, queued, synthesizing, delivering, playing, delivered, canceled, synth_failed, transport_failed, transport_timeout, and rejected-before-acceptance.
  - Verify: table-driven tests assert legal transitions and reject terminal-to-terminal mutation.
- [ ] 1.2 Generate an opaque request ID before queue insertion and validate its transport-safe alphabet.
  - Verify: IDs are unique, stable, non-empty, contain no whitespace/path separators/shell metacharacters, and are never derived from text or project.
- [ ] 1.3 Carry the ID through service jobs, local submit output, remote spool metadata, resident-player commands, and history records.
  - Verify: one accepted request can be correlated end to end without parsing filenames or spoken text.
- [ ] 1.4 Make lifecycle state and terminal-record ownership concurrency-safe.
  - Verify: `go test -race ./pkg/notify/...` covers concurrent stop, worker completion, and duplicate terminalization.

## 2. Submission and cancellation seams

- [ ] 2.1 Return `{status:accepted,request_id}` from `POST /notify`; preserve `202`, bounded response time, and the existing 400/503 acceptance boundary.
  - Verify: valid requests get an ID before injected slow synthesis runs; malformed and queue-full requests do not become accepted IDs.
- [ ] 2.2 Add the local submit/control adapter used by `bin/notify.sh` and external callers; existing fire-and-forget callers may ignore its output.
  - Verify: the adapter emits exactly one machine-readable ID on acceptance and remains exit-0/fail-soft on all failure paths.
- [ ] 2.3 Add `herald notify stop REQUEST_ID` with stable JSON output and bounded execution.
  - Verify: unknown, terminal, malformed, and active IDs produce deterministic results and never panic or hang.
- [ ] 2.4 Add `POST /notify/stop` with body `{request_id}` and the same result model as the CLI.
  - Verify: wrong method, malformed body, missing ID, unknown ID, and accepted cancellation have documented status/body pairs.
- [ ] 2.5 Ensure cancellation is never retried through a second transport by the adapter or shell fallback.
  - Verify: injected service timeout cannot cause duplicate stop attempts or duplicate history rows.

## 3. Queue and synthesis cancellation

- [ ] 3.1 Add a per-request cancellation signal owned by the queue/lifecycle registry.
  - Verify: stop-before-worker-start marks the job canceled and the synthesizer is not called.
- [ ] 3.2 Make the worker check cancellation at queue dequeue, before synthesis, after synthesis, and before delivery.
  - Verify: stop during each checkpoint yields one canceled terminal record and no later delivery.
- [ ] 3.3 Bound cancellation of an in-flight synthesizer/delivery context without changing the caller's fail-soft timeout contract.
  - Verify: blocked fakes receive context cancellation; the stop API itself remains bounded.
- [ ] 3.4 Define the race winner when stop and completion happen together.
  - Verify: exactly one terminal outcome is persisted; a delivered request is never rewritten as canceled and a canceled request is never delivered.

## 4. Remote spool and player control

- [ ] 4.1 Extend `pkg/notify/remote_spool.sh` and the generated shell path to write request-bearing metadata atomically with audio enqueue.
  - Verify: partial transfers are not visible as playable clips and a pending clip can be found by request ID.
- [ ] 4.2 Add resident-player control for `stop <request-id>` and make active-track ownership explicit.
  - Verify: stopping the matching active track interrupts it, removes only its pending metadata, and leaves unrelated clips and order unchanged.
- [ ] 4.3 Add fallback-drainer cancellation for pending clips without introducing unsafe arbitrary process killing.
  - Verify: a fallback drainer can remove a matching not-yet-playing clip; active cancellation with no ownership proof returns `stopped:false` and preserves playback.
- [ ] 4.4 Keep the resident player and fallback drainer as one delivery path with stale-lock recovery and fail-toward-sound behavior.
  - Verify: player absence, stale locks, malformed metadata, and control-channel failure do not silence unrelated notifications.
- [ ] 4.5 Preserve `--wait` semantics for the submitting request and define its behavior when that request is canceled.
  - Verify: `--wait` returns within its existing playback bound and does not wait forever on a canceled or missing clip.

## 5. History and compatibility

- [ ] 5.1 Add request ID to `Record` and add the closed `canceled` outcome with reasons for queued, in-flight, interrupted, and unconfirmed cancellation.
  - Verify: legacy records without an ID remain readable and new accepted requests append exactly one terminal row.
- [ ] 5.2 Centralize terminalization so service, local fallback, spool, and player races cannot append duplicate rows.
  - Verify: race tests count one row per accepted ID across all terminal paths.
- [ ] 5.3 Preserve mute behavior, service fallback carve-outs, config-divergence bypass, delivery timeouts, and single speech path.
  - Verify: existing Go and shell suites remain green plus focused regression tests for fallback/no-double-send.
- [ ] 5.4 Document the Jcode action contract: capture the returned ID, stop that exact ID on reclick, do not retry via another path, and treat `stopped:false` as best effort rather than proof of silence.
  - Verify: documentation includes example CLI/HTTP calls and explicit unknown/completed semantics.

## 6. Verification and acceptance

- [ ] 6.1 Run focused Go tests for lifecycle, API, queue, cancellation races, and history, including `-race`.
- [ ] 6.2 Run focused shell tests for spool metadata, resident-player control, fallback drainer, stale locks, and fail-soft bounds.
- [ ] 6.3 Run the full Herald test suite and static checks.
- [ ] 6.4 With explicit acceptance authorization, run one harmless short briefing, capture its ID, stop it through the real control API, then verify an unrelated notification still plays.
- [ ] 6.5 Commit and archive only after all requirements and external acceptance gates pass.
