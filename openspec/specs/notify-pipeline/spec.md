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

### Requirement: Voice configuration supports prosody parameters

`voices.json` SHALL support optional per-project and default `speed` and blend voice
expressions; absent fields SHALL preserve today's behavior byte-for-byte on the wire.

#### Scenario: Legacy configuration untouched

- **WHEN** a voices.json entry has only a voice string
- **THEN** the synthesized request body is identical to the pre-change wire format

#### Scenario: Blend passes through

- **WHEN** a project's voice is `kokoro:af_heart+af_bella(2)`
- **THEN** the request's `voice` field is `af_heart+af_bella(2)` and a service rejection
  surfaces the payload snippet in the `synth_failed` reason

### Requirement: Spoken lines are prose

The spoken notification text contract SHALL require one natural conversational sentence
with speech-hostile abbreviations expanded; written summary density rules SHALL NOT apply
to the spoken line.

#### Scenario: Jargon expanded

- **WHEN** a completion event mentions a pull request and e2e tests
- **THEN** the spoken line says "pull request" and "end to end", not "PR" and "e2e"

### Requirement: Herald is reachable as a service, not only as an executable

Herald SHALL expose its notification path over a network API so that any caller — on any host
in the tailnet, in any language — can send a notification and manage notification state without
executing Herald's scripts or knowing its on-disk formats.

The listener SHALL bind to loopback and the host's tailnet address only, never to a
broadcast address. The bind address IS the access control; no credential is required, matching
the posture the Kokoro compose module already documents.

A send request SHALL be ACCEPTED rather than completed: the service returns once the request is
queued, and synthesis and delivery proceed asynchronously. The history record, not the response,
reports the outcome.

#### Scenario: A foreign caller sends a notification

- **WHEN** a caller on another tailnet host issues one HTTP request carrying text and a project
- **THEN** speech is delivered and exactly one history record is appended, with the caller
  having read or written no Herald state file

#### Scenario: Acceptance does not wait for synthesis

- **WHEN** a send request is issued while synthesis is slow
- **THEN** the caller receives its acceptance response without waiting for synthesis, and one
  history record still reports the eventual outcome

#### Scenario: The listener is not broadly exposed

- **WHEN** the service is running
- **THEN** it answers on loopback and the tailnet address, and on no other interface

#### Scenario: Control is reachable over the same API

- **WHEN** a caller mutes, unmutes, or reads status or history over the API
- **THEN** the result is identical to performing the same operation through the CLI, because
  one implementation decides it

### Requirement: The service is an optimisation, never a dependency

Delivery SHALL NOT depend on the service being healthy. When the service is unreachable, a
notification SHALL still be synthesized, delivered, and recorded through Herald's local path.
Exactly one path SHALL deliver any given notification.

#### Scenario: Service down, notification still speaks

- **WHEN** the service is stopped, wedged, or was never started, and a caller sends a
  notification through Herald's own pipe
- **THEN** the notification is delivered and recorded through the local path, and the caller
  sees no error

#### Scenario: No double delivery across the transition

- **WHEN** notifications are sent while the service is starting or stopping
- **THEN** each notification is delivered exactly once — never once by the service and again by
  the fallback

#### Scenario: A slow service is not a failed service

- **WHEN** the service accepts a request and synthesis then takes longer than the caller's own
  timeout
- **THEN** the caller does NOT fall back, because a response already acknowledged acceptance —
  the notification is spoken once, not twice

### Requirement: Notification state has exactly one owner

Mute state, delivery history, and status readout SHALL be implemented once, in Herald's own
package, and every surface — HTTP API, CLI, and harness command files — SHALL be a thin adapter
over that implementation. No surface SHALL reimplement Herald's on-disk formats.

#### Scenario: Mute agrees across surfaces

- **WHEN** mute is set through one surface and observed through another
- **THEN** both report the same state and the same expiry, because neither computed it
  independently

#### Scenario: Command files carry no state logic

- **WHEN** a harness command file's control branches are inspected
- **THEN** they contain no duration arithmetic, epoch computation, or state-file writes — only
  calls into Herald

### Requirement: The deployed pipeline has exactly one configuration instance

The service and the callers that speak to it SHALL read their deployment configuration from a
single shared instance, not from independent resolutions of the same precedence rule. A value
SHALL NOT be captured into the service's supervisor definition at install time, because a
captured value is a copy that goes stale the moment the shared configuration changes.

Because the configuration is consumed by both a shell reader and a service-manager reader, its
format SHALL be restricted to what both accept.

#### Scenario: A configuration change reaches the service

- **WHEN** the shared configuration is edited and the service is restarted
- **THEN** the service serves the new values, with no reinstall or re-provisioning step required

#### Scenario: Caller and service never disagree about the deployment

- **WHEN** a caller and the running service both resolve a configuration value
- **THEN** they resolve the same value, because they read the same instance rather than agreeing
  by coincidence

#### Scenario: An explicit override still wins

- **WHEN** a caller explicitly sets a configuration value in its environment
- **THEN** that value takes precedence over the shared configuration, which is otherwise the
  source of truth

### Requirement: A caller describing a different pipeline does not use the service

A caller SHALL NOT hand its notification to the deployed service when its own resolved
configuration identifies a different notification pipeline; it SHALL take Herald's local path
instead. Silently routing such a caller to the deployed service records its notification in
state it did not choose and synthesizes it through an engine it did not select.

#### Scenario: An isolated caller stays isolated

- **WHEN** a caller sets its own state location or synthesis engine and sends a notification
- **THEN** the notification is handled entirely by the local path, and the deployed service's
  state is untouched

#### Scenario: Isolation is not a global opt-out

- **WHEN** a caller whose configuration matches the deployment sends a notification immediately
  after an isolated caller did
- **THEN** it is still handled by the service — one caller's isolation never disables the
  service for others

