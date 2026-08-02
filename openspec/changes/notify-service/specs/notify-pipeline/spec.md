# notify-pipeline Spec Delta — notify-service

## ADDED Requirements

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

A caller whose resolved configuration identifies a different notification pipeline than the
deployed one SHALL NOT hand its notification to the deployed service, and SHALL instead take
Herald's local path. Silently routing such a caller to the deployed service records its
notification in state it did not choose and synthesizes it through an engine it did not select.

#### Scenario: An isolated caller stays isolated

- **WHEN** a caller sets its own state location or synthesis engine and sends a notification
- **THEN** the notification is handled entirely by the local path, and the deployed service's
  state is untouched

#### Scenario: Isolation is not a global opt-out

- **WHEN** a caller whose configuration matches the deployment sends a notification immediately
  after an isolated caller did
- **THEN** it is still handled by the service — one caller's isolation never disables the
  service for others
