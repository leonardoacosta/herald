# attention-channels Spec Delta — moshi-hook-parity

## ADDED Requirements

### Requirement: Herald owns the attention-channel doctrine

Herald SHALL maintain `docs/attention-channels.md` with a per-event, per-harness parity
matrix (wired / not wired / platform limit), each cell citing the harness config line or
the limiting fact. Harness wiring changes SHALL update the matrix in the same change.

#### Scenario: Matrix stays truthful

- **WHEN** a harness's moshi-hook wiring changes
- **THEN** the same change updates the matrix row and its citation

### Requirement: Blocked sessions are visible on mobile in every harness

Every harness whose platform exposes an ask/permission hook SHALL forward it to
moshi-hook, so a session blocked on the operator is distinguishable from a working one on
the phone. A harness that cannot emit such an event SHALL be recorded as a platform limit
with the limiting fact cited.

#### Scenario: Blocked codex session

- **WHEN** codex blocks on a permission request
- **THEN** the event reaches the Moshi inbox

#### Scenario: Platform limit recorded honestly

- **WHEN** a harness has no hook type for operator-blocking events
- **THEN** the matrix records the limit and no wiring is faked around it
