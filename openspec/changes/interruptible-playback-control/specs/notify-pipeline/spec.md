## ADDED Requirements

### Requirement: Accepted notifications have stable cancellation identity
Herald SHALL assign a unique request ID to every accepted notification and preserve that identity through queueing, synthesis, delivery, cancellation, and terminal history.

#### Scenario: Notification is accepted
- **WHEN** a valid notification is accepted by the CLI, pipe, or HTTP service
- **THEN** the caller receives the request ID and the request is eligible for scoped cancellation

#### Scenario: Existing caller ignores the response
- **WHEN** an existing fail-soft caller ignores the request ID
- **THEN** delivery and history behavior remain compatible with the existing contract

### Requirement: Scoped cancellation is idempotent
Herald SHALL provide a bounded, fail-soft stop operation that targets exactly one request ID and is safe to repeat.

#### Scenario: Queued request is canceled
- **WHEN** a caller stops a request before synthesis begins
- **THEN** Herald removes or marks only that request canceled, does not synthesize or deliver it, and records one terminal cancellation outcome

#### Scenario: Active request is canceled
- **WHEN** a caller stops a request while its matching clip is playing
- **THEN** the playback host interrupts that clip if supported, preserves unrelated queued clips, and records one terminal cancellation outcome

#### Scenario: Request is already terminal
- **WHEN** a caller stops an unknown, completed, failed, or already-canceled request ID
- **THEN** Herald returns a stable no-op result, does not affect another request, and does not append a duplicate history row

### Requirement: Cancellation is exposed through CLI and service seams
Herald SHALL expose equivalent scoped cancellation through `herald notify stop <request-id>` and `POST /notify/stop`.

#### Scenario: HTTP cancellation
- **WHEN** a tailnet caller posts a valid request ID to `/notify/stop`
- **THEN** the service returns a bounded deterministic result equivalent to the CLI operation

#### Scenario: Invalid cancellation request
- **WHEN** the method or request body is invalid
- **THEN** Herald rejects it without changing playback or history and preserves the service's fail-soft caller contract

### Requirement: Cancellation preserves single-path and history invariants
Cancellation SHALL not create a second speech path, duplicate delivery, duplicate history record, global mute side effect, or fallback double-send.

#### Scenario: Cancellation races acceptance
- **WHEN** stop and notification acceptance race
- **THEN** exactly one lifecycle outcome wins for that request ID and no unrelated request is stopped

#### Scenario: Playback control is unavailable
- **WHEN** the remote playback host cannot interrupt a matching active clip
- **THEN** Herald reports a bounded best-effort result, preserves unrelated playback, and records the limitation without claiming that audio stopped
