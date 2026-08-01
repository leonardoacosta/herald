# notify-pipeline Specification

## Purpose

Define Herald's ownership of the notification pipeline and the fail-soft delivery
contract that every harness consumer relies on.
## Requirements
### Requirement: Herald is the sole owner of the notify pipeline

Herald SHALL own the notify pipe (`bin/notify.sh`), the synthesis client and history store
(`pkg/notify`, `herald` binary), and the Kokoro compose module. No other repo SHALL carry a
copy of any of these; consumers reach the pipe exclusively through `$HERALD/bin/notify.sh`.

#### Scenario: Consumer resolves the pipe

- **WHEN** cc's `say_notify` fires
- **THEN** it resolves `$HERALD/bin/notify.sh` and never a herdr-shepherd path

#### Scenario: Former owner is clean

- **WHEN** herdr-shepherd is grepped for `pkg/notify` outside archived changes
- **THEN** no matches remain

### Requirement: The fail-soft contract survives the move unchanged

Every herald entry point SHALL exit 0 on every failure path, bound its wall clock, and
append exactly one history record per attempt (`delivered`, `synth_failed`,
`transport_timeout`, `transport_failed`, `muted`).

#### Scenario: Synthesis service down

- **WHEN** the Kokoro base URL is unset or unreachable
- **THEN** the pipe exits 0 within its bound and a `synth_failed` record is appended

#### Scenario: Playback host asleep

- **WHEN** ssh to the playback host exceeds the playback timeout
- **THEN** the pipe exits 0 and a `transport_timeout` record names the host and bound

#### Scenario: Operator mute is active

- **WHEN** the shared Herald mute file contains a future epoch expiry
- **THEN** the pipe exits 0 before synthesis or transport and appends one `muted` record

### Requirement: Voice state is manageable through safe herald CLI seams

Herald SHALL expose read/manage subcommands (`herald notify …`) with stable JSON/line
output for effective-voice state, catalog discovery, validated mapping mutations, and a
fixed-text audition — usable by any UI surface without reimplementing JSON or Kokoro
semantics.

#### Scenario: Effective state readable without the catalog

- **WHEN** the Kokoro catalog is unreachable
- **THEN** effective-voice readout still works from local configuration and only
  management writes are refused

#### Scenario: Audition never leaks

- **WHEN** an audition runs
- **THEN** no `voices.json` write occurs, no notify history record is appended, and the
  playback host is not contacted

### Requirement: Persistence is atomic and legacy-preserving

Mapping mutations SHALL write via same-directory temp file + rename with mode 0600, and
SHALL preserve legacy bare (ElevenLabs) values and unrelated mappings byte-for-byte.

#### Scenario: Failed write leaves state intact

- **WHEN** a write or rename fails mid-mutation
- **THEN** the prior valid `voices.json` remains readable and resolution is unaffected
