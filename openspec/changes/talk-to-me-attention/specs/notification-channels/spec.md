# notification-channels capability delta

## ADDED Requirements

### Requirement: NC1 Bounded ntfy text delivery

Herald SHALL own opt-in ntfy publishing through configured origins and topic with title, public_text, priority and safe session navigation. It SHALL distinguish published from human receipt, use bounded independent channel workers and preserve speech success during text failure.

#### Scenario: Text reaches subscriber

- **WHEN** an approved event uses a configured ntfy server and subscribed test client
- **THEN** the public wrapper, HTTP history, real server response and client show the correlated text with the intended priority, without claiming it was read

#### Scenario: Slow or ambiguous provider

- **WHEN** ntfy stalls, redirects, rejects or loses its response after possible acceptance
- **THEN** bounds and conservative retry rules in design.md section 5 apply, no secret reaches a redirect, and a successful speech channel is not replayed

#### Scenario: Unconfigured private service

- **WHEN** ntfy is disabled or a configured private no-auth origin is used
- **THEN** disabled publishing makes no external request, and private service use does not silently alter server ACLs or expose Herald

### Requirement: NC2 Privacy and safe navigation

Channel output SHALL use deliberately prepared public_text or a generic sensitive-event template. Session navigation SHALL resolve opaque references through configured safe templates, never execute commands or accept arbitrary provider destinations.

#### Scenario: Sensitive completion

- **WHEN** an event has private details and a safe public summary
- **THEN** the phone and attention history contain only approved public fields and the safe session reference

#### Scenario: Hostile reference or payload

- **WHEN** an event supplies a command, javascript URL, control characters, destination URL, or a secret-bearing detail
- **THEN** the invalid fields are rejected or replaced by a generic notification, no injected header or command executes, and no detail is fetched or sent externally

### Requirement: NC3 Listen-later speech attachments

Herald SHALL deliver optional audio attachments synthesized by its existing Kokoro path with existing voice and briefing constraints, <=10 MiB clip bytes, private temporary storage and cleanup. Text SHALL remain independent and audio SHALL be labeled listen-later, not guaranteed autoplay.

#### Scenario: Text and audio requested

- **WHEN** an explicit brief requests text and audio on a supported subscribed client
- **THEN** text arrives independently, audio can be downloaded and manually played, both share event correlation, and any configured speech output remains serialized

#### Scenario: Synthesis upload or expiry failure

- **WHEN** Kokoro fails, a clip exceeds the limit, upload fails or attachment expires
- **THEN** text remains available, failure or expiry is observable, temporary bytes are removed, and no second speech implementation or unbounded retry is used

### Requirement: NC4 Lifecycle and backward compatibility

New channels SHALL preserve existing mute, stop, speech serialization, fail-soft bounds, single-file deployment configuration and service-sync lifecycle. Multichannel partial outcomes SHALL remain observable without changing existing history vocabulary.

#### Scenario: Legacy caller and unavailable daemon

- **WHEN** an existing say_notify call cannot connect to Herald
- **THEN** the existing local speech fallback and exactly one physical-attempt record remain available within bounds

#### Scenario: Accepted work during shutdown

- **WHEN** the service receives shutdown while text, speech and deferred events exist
- **THEN** bounded lifecycle terminalizes in-flight attempts honestly, preserves unexpired unclaimed deferred work, and does not replay uncertain channels

#### Scenario: Cancellation and partial delivery

- **WHEN** speech is canceled after text has already published
- **THEN** speech cancellation retains existing target-aware semantics, text stays published, and the event is not falsely labeled wholly undelivered
