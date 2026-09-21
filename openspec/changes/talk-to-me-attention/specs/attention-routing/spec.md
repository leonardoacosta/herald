# attention-routing capability delta

## ADDED Requirements

### Requirement: AR1 Versioned attention admission

Herald SHALL implement the v1 envelope and public interfaces in design.md section 2. Admission SHALL durably reserve work before 202 without invoking providers. Legacy send behavior and connect-phase-only fallback SHALL remain unchanged.

#### Scenario: Valid request with stalled providers

- **WHEN** a valid event arrives while Kokoro and Jev are stalled
- **THEN** POST /attention returns its durable event_id within the local p95 100 ms budget and GET /attention/history exposes acceptance

#### Scenario: Invalid or unavailable admission

- **WHEN** schema is invalid, capacity is exhausted, or persistence fails
- **THEN** the endpoint returns respectively 400, 503, or 503 without delivery, wrappers still exit 0 within their bound, and health exposes persistence failure

#### Scenario: Ambiguous response

- **WHEN** the connection was established but the response is lost or 503 is received
- **THEN** the wrapper does not invoke local fallback or resubmit, and no duplicate channel operation occurs

### Requirement: AR2 Durable identity and channel claims

Herald SHALL deduplicate identical event UUIDs and canonical task/session/kind/revision identities, reject conflicting UUID reuse, and serialize durable per-channel claims across local and service execution. It SHALL never infer cross-emitter equivalence from prose alone.

#### Scenario: Concurrent duplicate

- **WHEN** inline agent, hook and local fallback submit the same canonical event concurrently
- **THEN** one channel operation is claimed, duplicate receipt is recorded, and different-content UUID reuse returns 409

#### Scenario: Uncertain crash

- **WHEN** a process dies after a durable channel claim but before terminal evidence
- **THEN** recovery marks the channel uncertain and does not replay it, status exposes its event ID, and explicit operator heard/dismiss/retry reconciliation resolves that channel without replaying successful siblings, while unrelated unclaimed work can continue

#### Scenario: Missing canonical identity

- **WHEN** two legacy sources lack a shared task or revision
- **THEN** no semantic dedupe is claimed and correlation_unavailable is visible

### Requirement: AR3 Deterministic attention and aggregation

Herald SHALL enforce the precedence, defaults, budgets and expiry rules in design.md section 4. Workers SHALL not independently announce completion, and coordinator completion SHALL require all_work_terminal. Mandatory decisions SHALL bypass model suppression but never operator channel prohibitions.

#### Scenario: Worker burst and final completion

- **WHEN** five workers complete before their coordinator finishes
- **THEN** worker completion events are recorded as suppressed and one final eligible coordinator completion is delivered

#### Scenario: Quiet hours and required input

- **WHEN** a decision event arrives in configured quiet hours
- **THEN** allowed low-priority text is used or the event is deferred, and speech never bypasses the operator restriction

#### Scenario: Routine storm and expired work

- **WHEN** routine events exceed the project budget or an event expires
- **THEN** excess events coalesce by latest task revision, expired events terminalize without delivery, and mandatory alerts use their separate bounded safety policy

### Requirement: AR4 Shared policy and decision history

Herald SHALL expose atomic policy management and versioned attention history, separate decisions from legacy delivery outcomes, preserve old readers, and detect default-service configuration divergence including new routing settings.

#### Scenario: Explain a suppressed event

- **WHEN** the operator reads attention history after deduplication or semantic suppression
- **THEN** the event, reason, policy hash, optional model version and per-channel state are visible without secrets, with no fake delivered speech row

#### Scenario: Invalid or divergent configuration

- **WHEN** a policy edit is invalid or caller config differs from default deployed service
- **THEN** invalid edits preserve prior policy, errors are visible, and divergent callers use bounded local evaluation rather than the wrong service

#### Scenario: Corrupt journal or full disk

- **WHEN** state has a truncated trailing record, interior corruption, or failed write
- **THEN** only the trailing partial record is recoverable, interior corruption degrades visibly without uncertain replay, and no unrecorded accepted work is claimed

### Requirement: AR5 Presence and channel restrictions

Herald SHALL support manual presence and optional capability-probed macOS presence with the 60-second freshness limit, expose unknown states, and never collect microphone, camera or calendar data. Focus, meeting and headphone restrictions SHALL be applied according to explicit operator settings.

#### Scenario: Fresh quiet presence

- **WHEN** a configured presence provider reports a meeting or Focus mode
- **THEN** automatic speech is restricted and allowed text/defer policy is used

#### Scenario: Missing headphones evidence

- **WHEN** headphones-only is configured but the provider is absent, stale or unsupported
- **THEN** public speech is not permitted by guess, status shows the limitation, and allowed text or deferral preserves the event

### Requirement: AR6 Acknowledgment deferral and reminders

Herald SHALL provide explicit scoped acknowledgments and deferral, optional two-reminder scheduling, durable restart behavior and expiry as defined in design.md section 6. Acknowledgment SHALL never approve agent actions or be inferred from delivery.

#### Scenario: Ack before reminder

- **WHEN** the operator acknowledges an event through CLI or a supported private ntfy action
- **THEN** the acknowledgment is recorded once and future reminders are canceled without executing or approving work

#### Scenario: Restart and supersession

- **WHEN** a deferred event survives restart but expires or its task is resolved before its timer fires
- **THEN** the service rechecks state and suppresses stale reminders rather than replaying them

#### Scenario: Invalid action and service outage

- **WHEN** a forged or expired nonce is submitted, or local fallback cannot schedule a future timer
- **THEN** the action is rejected without mutation, and unavailable timers remain durable and visibly pending rather than spawning detached schedulers
