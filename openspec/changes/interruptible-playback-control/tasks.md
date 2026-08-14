# Tasks — interruptible-playback-control

## 1. Request identity and lifecycle model

- [ ] 1.1 Add a request ID and explicit lifecycle state to accepted notify jobs without changing existing text, project, voice, or history fields.
  - Verify: unit tests cover accepted, queued, synthesizing, delivering, delivered, canceled, failed, and unknown IDs.
- [ ] 1.2 Make request IDs stable across service queue, local fallback, remote spool metadata, and history records.
  - Verify: one accepted request produces one ID in the acceptance response and exactly one terminal history record.

## 2. Cancellation API

- [ ] 2.1 Add an idempotent `herald notify stop <request-id>` CLI seam with bounded, fail-soft output.
  - Verify: unknown, completed, and already-canceled IDs return stable no-op results without affecting other jobs.
- [ ] 2.2 Add `POST /notify/stop` for tailnet callers with the same result model as the CLI.
  - Verify: method, malformed body, unknown ID, and accepted cancellation responses are deterministic and documented.
- [ ] 2.3 Return request IDs from `POST /notify` and the caller-facing pipe/control adapter.
  - Verify: existing callers remain compatible when they ignore the response, and Jcode can capture the ID.

## 3. Queue and playback interruption

- [ ] 3.1 Cancel queued jobs before synthesis and prevent them from entering the playback spool.
  - Verify: canceled queued work never synthesizes, delivers, or appends a delivered record.
- [ ] 3.2 Add request-scoped cancellation metadata to the remote spool/player protocol.
  - Verify: canceling one queued or active clip preserves unrelated clips and queue order.
- [ ] 3.3 Interrupt an active clip only when its request ID matches; resolve races toward no duplicate speech and no unrelated stop.
  - Verify: active cancellation tests exercise stop-before-start, stop-during-synthesis, stop-during-delivery, and stop-after-completion.

## 4. History and compatibility

- [ ] 4.1 Add a cancellation outcome/reason that preserves the one-record-per-accepted-request invariant.
  - Verify: every race path appends exactly one terminal row and no fallback path speaks twice.
- [ ] 4.2 Preserve fail-soft bounds, service fallback behavior, mute semantics, and the single speech path.
  - Verify: existing `go test ./pkg/notify/...` and shell integration tests remain green.
- [ ] 4.3 Document the contract for Jcode's rendered-artifact briefing actions.
  - Verify: docs specify capture ID, stop same ID on reclick, no retry, and best-effort completion semantics.

## 5. Integration acceptance

- [ ] 5.1 Run focused Go and shell tests for request identity, API, queue, spool, player, and history behavior.
- [ ] 5.2 Run the full Herald test suite and static checks.
- [ ] 5.3 With explicit acceptance authorization, run one harmless short briefing and stop it via the real API; verify the active clip stops and a second unrelated clip still plays.
- [ ] 5.4 Commit and archive only after all requirements and external acceptance gates pass.
