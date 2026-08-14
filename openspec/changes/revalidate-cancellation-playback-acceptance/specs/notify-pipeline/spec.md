# notify-pipeline — deltas for revalidate-cancellation-playback-acceptance

## ADDED Requirements

### Requirement: Repeatable deployed acceptance validation for cancellation and playback

Herald SHALL provide an explicit-only, operator-invoked acceptance validation that
exercises the deployed notify service, cancellation controls, and real playback
boundary without mutating the playback host or service lifecycle, and SHALL emit one
durable machine-readable evidence report per run in which every accepted request maps
to exactly one terminal history row.

#### Scenario: Version-aligned live acceptance run passes

- **GIVEN** `herald-notify.service` is healthy and its running version matches the
  on-disk `bin/herald` and the shared config file is non-divergent
- **WHEN** the operator runs the acceptance harness with live authorization
- **THEN** the delivery, queued-cancellation, active-cancellation,
  unrelated-survival, idempotent-stop, serialization, mute, and HTTP-contract rows
  are exercised, each correlated by request ID to boundary evidence and exactly one
  terminal history row, and a report with verdict `pass` is written

#### Scenario: Alignment gate blocks a stale deployment

- **WHEN** the running service version differs from the on-disk binary or the
  resolved config diverges from the shared file
- **THEN** the harness aborts before playing any audio, reports the mismatch and the
  remediation (`bin/service-sync.sh`), and does not restart or modify the service

#### Scenario: Playback host unavailable yields partial, not silent pass

- **WHEN** boundary evidence cannot be collected because the playback host is
  unreachable
- **THEN** affected rows are reported as `blocked` or `not-exercised`, the run
  verdict is at best `partial`, and no row is reported as passed without evidence
