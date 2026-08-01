# notify-pipeline Spec Delta — deep-briefings

## ADDED Requirements

### Requirement: On-demand long-form spoken briefings

The system SHALL provide `say_brief` — same fail-soft contract as `say_notify` with a
bound sized for long synthesis — and a `/notify brief` composition surface producing a
60–150-word spoken digest. Briefings SHALL fire only on explicit operator request, never
from hooks or automatic completion events.

#### Scenario: Explicit request produces one digest

- **WHEN** the operator says "brief me" or runs `/notify brief`
- **THEN** exactly one spoken digest is synthesized and delivered, and one history record
  is appended

#### Scenario: Never automatic

- **WHEN** a Stop, SessionEnd, or agent-completion event fires
- **THEN** no `say_brief` call occurs (grep over hook sources returns no call sites)

#### Scenario: Long synthesis failure stays soft

- **WHEN** synthesis of a digest fails or exceeds its bound
- **THEN** `say_brief` exits 0 within the bound and records the failure
