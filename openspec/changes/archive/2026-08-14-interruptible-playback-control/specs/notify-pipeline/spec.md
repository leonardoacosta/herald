## ADDED Requirements

### Requirement: Accepted notifications have an opaque stable identity

Herald SHALL assign a unique opaque request ID before accepting a valid notification into the service queue or local delivery pipeline. The ID SHALL contain only transport-safe characters, SHALL not contain caller text, and SHALL remain stable through queueing, synthesis, delivery, cancellation, remote spool/player control, and terminal history.

#### Scenario: HTTP notification is accepted

- **WHEN** a valid `POST /notify` request is accepted
- **THEN** Herald returns `202` with `{"status":"accepted","request_id":"..."}` before synthesis or delivery begins

#### Scenario: Existing caller ignores the response

- **WHEN** a fail-soft caller ignores the returned ID
- **THEN** its existing delivery, timeout, fallback, mute, and history behavior remains compatible

#### Scenario: Rejected request has no accepted identity

- **WHEN** validation fails or the bounded queue is full
- **THEN** Herald rejects the request using the existing boundary and does not expose it as an accepted cancellable request

### Requirement: Scoped cancellation is bounded and idempotent

Herald SHALL provide `herald notify stop REQUEST_ID` and `POST /notify/stop` with equivalent semantics. Both SHALL be bounded, fail-soft, scoped to exactly one ID, and safe to repeat. A cancellation result SHALL distinguish whether playback was confirmed stopped.

#### Scenario: Queued request is canceled

- **WHEN** a caller stops a request before synthesis begins
- **THEN** only that request transitions to canceled, synthesis and delivery are skipped, and one terminal `canceled` history record is written

#### Scenario: In-flight request observes cancellation

- **WHEN** a caller stops a request during synthesis or delivery and the active stage observes its cancellation context
- **THEN** that request stops progressing, no later stage delivers it, and one terminal `canceled` record is written

#### Scenario: Matching resident-player clip is canceled

- **WHEN** a caller stops a request whose matching clip is active in the resident player
- **THEN** only that clip is interrupted, unrelated queued clips remain in arrival order, and the response reports `stopped:true`

#### Scenario: Active fallback clip lacks ownership proof

- **WHEN** a caller stops a request whose active fallback playback cannot be safely matched to the request ID
- **THEN** Herald does not kill an arbitrary player, preserves unrelated playback, returns a bounded best-effort result with `stopped:false`, and records the limitation

#### Scenario: Unknown or terminal request is stopped

- **WHEN** a caller stops an unknown, delivered, failed, transport-terminal, or already-canceled ID
- **THEN** Herald returns a stable no-op result, does not affect another request, and appends no additional history row

### Requirement: Cancellation API wire contracts are deterministic

`POST /notify/stop` SHALL accept exactly `{ "request_id": "..." }` and SHALL return the same result model as the CLI. Malformed bodies, missing IDs, invalid methods, and invalid IDs SHALL not change playback or history. The local submit/control adapter SHALL expose the accepted request ID without requiring callers to parse history or spool filenames.

#### Scenario: Valid cancellation response

- **WHEN** a known non-terminal request is stopped
- **THEN** the response includes `status`, `request_id`, `stage`, and boolean `stopped` fields, with status `canceled` or a documented no-op status

#### Scenario: Cancellation is not retried through fallback

- **WHEN** the control request times out after its transport attempt reaches the service
- **THEN** the caller does not submit a second cancellation through the local path

### Requirement: Request identity is carried by the remote playback protocol

The remote spool and resident-player protocol SHALL associate every playable clip with its request ID using atomic metadata publication. Pending cancellation SHALL remove only the matching request. Active interruption SHALL require proof that the current player track belongs to the requested ID.

#### Scenario: Partial enqueue

- **WHEN** audio transfer or metadata publication is interrupted
- **THEN** no partial file is visible as a playable clip and the request receives one terminal transport outcome

#### Scenario: Unrelated queue entries are preserved

- **WHEN** one pending or active request is canceled while other clips exist
- **THEN** unrelated clips remain playable and their relative arrival order is unchanged

#### Scenario: Player control is unavailable

- **WHEN** the resident player or its control channel is absent, wedged, or unable to prove ownership
- **THEN** cancellation remains bounded, does not silence unrelated clips, and never claims confirmed interruption

### Requirement: Cancellation preserves history and delivery invariants

Cancellation SHALL use one centralized terminalization path. Every accepted request SHALL produce exactly one terminal history record. The history outcome vocabulary SHALL remain closed and include a `canceled` outcome with a reason. Cancellation SHALL not introduce a second speech path, duplicate delivery, duplicate history row, global mute side effect, or service/local fallback double-send.

#### Scenario: Stop races acceptance or completion

- **WHEN** stop races queue acceptance, worker completion, or playback completion
- **THEN** exactly one legal terminal outcome wins for that request ID and no unrelated request is stopped

#### Scenario: Legacy history remains readable

- **WHEN** existing history rows do not contain a request ID
- **THEN** history reads and existing management surfaces remain compatible while new rows include the ID

#### Scenario: Fail-soft bound survives cancellation

- **WHEN** any cancellation path fails, times out, or encounters malformed state
- **THEN** the caller exits successfully within its bound, the failure is represented in history where the request was accepted, and unrelated notification delivery continues
