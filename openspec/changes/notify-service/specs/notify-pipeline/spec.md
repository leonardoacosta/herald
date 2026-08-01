# notify-pipeline Spec Delta — notify-service

## ADDED Requirements

### Requirement: Herald is reachable as a service, not only as an executable

Herald SHALL expose its notification path over a network API so that any caller — on any host
in the tailnet, in any language — can send a notification and manage notification state without
executing Herald's scripts or knowing its on-disk formats.

The listener SHALL bind to loopback and the host's tailnet address only, never to a
broadcast address. The bind address IS the access control; no credential is required, matching
the posture the Kokoro compose module already documents.

#### Scenario: A foreign caller sends a notification

- **WHEN** a caller on another tailnet host issues one HTTP request carrying text and a project
- **THEN** speech is delivered and exactly one history record is appended, with the caller
  having read or written no Herald state file

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
