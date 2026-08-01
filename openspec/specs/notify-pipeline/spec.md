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

### Requirement: One notification plays at a time

The playback host SHALL play at most one notification clip at any moment. Concurrent notify
calls SHALL be spooled and played in arrival order rather than mixed, and no clip SHALL be
discarded because another was playing when it arrived.

Serialization SHALL fail toward sound: any ambiguous lock state resolves to playing the clip,
never to suppressing it.

Playback SHALL begin without a perceptible delay attributable to acquiring the audio device.
A resident player MAY hold the output device open to achieve this, and SHALL release it after
an idle window. Whatever plays the spool, delivery SHALL NOT depend on it being healthy: if a
resident player is absent or wedged, clips SHALL still play.

#### Scenario: Concurrent calls do not overlap

- **WHEN** two notify calls deliver audio within the playback window of each other
- **THEN** the second clip begins only after the first finishes, and both are played

#### Scenario: A clip arriving mid-playback extends the stream

- **WHEN** audio is already playing and a new clip is spooled
- **THEN** it plays immediately after the current clip, with no second player process started

#### Scenario: A dead player never mutes the host

- **WHEN** the process draining the spool dies mid-clip, leaving its lock behind
- **THEN** the next notify call breaks the stale lock and its audio plays

#### Scenario: The uncontended path is unchanged

- **WHEN** a single notify call arrives with an empty spool and no drainer running
- **THEN** it plays without waiting, and the pipe still records `delivered` on the same terms

#### Scenario: Sequential notifications start promptly

- **WHEN** two notify calls arrive several seconds apart, far enough that they cannot batch
- **THEN** neither is preceded by an audible device-acquisition pause

#### Scenario: A missing resident player is not a silence

- **WHEN** no resident player is running or it fails to start
- **THEN** the spool is still drained and the audio still plays

