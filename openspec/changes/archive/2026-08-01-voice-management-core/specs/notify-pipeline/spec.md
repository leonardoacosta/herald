# notify-pipeline Spec Delta — voice-management-core

## ADDED Requirements

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
