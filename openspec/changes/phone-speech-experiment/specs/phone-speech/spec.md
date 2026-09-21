# phone-speech capability delta

## ADDED Requirements

### Requirement: PS1 Explicit device capability and activation

Herald SHALL represent automatic phone speech as unsupported, unverified or verified for a
specific device/OS/client version. It SHALL remain off unless that device has an approved
activation and successful acceptance evidence. Investigation SHALL not install an app or
automation or grant permissions without the separate activation boundary.

#### Scenario: No device or incompatible client

- **WHEN** a device is not selected or its installed client cannot automatically play clips
- **THEN** capability is unverified or unsupported with an explanation, no autoplay is claimed,
  and text plus listen-later audio remain the supported route

#### Scenario: Approved device passes the trial

- **WHEN** a selected device passes the defined connected/locked/quiet trial and activation is approved
- **THEN** its exact capability/version is recorded and automatic speech can be enabled for that device only

### Requirement: PS2 One policy-controlled playback path

A supported phone adapter SHALL consume Herald-synthesized artifacts, enforce the same
per-event identity and user privacy rules, serialize playback, and never synthesize its own
speech. Automatic events SHALL remain short announcements rather than briefings.

#### Scenario: Duplicate clip while locked

- **WHEN** the same valid event is delivered twice to a verified connected locked device
- **THEN** exactly one clip plays without overlap within the trial latency bound and the event receipt identifies the observed playback

#### Scenario: Quiet expired or offline event

- **WHEN** the event is prohibited by mute/quiet policy, expires before reconnection, or cannot be fetched
- **THEN** no forbidden or stale clip plays, failure or suppression is recorded, and no catch-up speech backlog is emitted

### Requirement: PS3 Honest receipts and fallback

The experiment SHALL distinguish publication, artifact retrieval, observed playback and
operator acknowledgment. Missing playback evidence SHALL be unconfirmed, not heard. A failed
audio route SHALL preserve text/listen-later fallback without duplicate pushes or speech.

#### Scenario: Publish succeeds but audio cannot play

- **WHEN** ntfy accepts a message but the OS prevents background playback
- **THEN** history shows published and playback unconfirmed or unsupported, and the user can still open the text or attachment

#### Scenario: Capability changes after upgrade

- **WHEN** the recorded OS/client version changes or permissions are revoked
- **THEN** automatic speech returns to unverified/off pending a new trial while ordinary text delivery remains available
