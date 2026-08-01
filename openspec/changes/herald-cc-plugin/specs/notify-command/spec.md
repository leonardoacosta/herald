# notify-command Spec Delta — herald-cc-plugin

## ADDED Requirements

### Requirement: A live control surface backed by herald

The `/notify` command SHALL be shipped by the herald plugin and SHALL expose status,
history readout, mute/unmute with expiry, an audible round-trip test, a read-only voices
view, and default message-send — all against herald's pipe and state, with no reference to
any retired transport.

#### Scenario: Status without a working pipe

- **WHEN** `/notify status` runs with `$HERALD` unset
- **THEN** the command reports the unset variable as the cause and exits cleanly

#### Scenario: Mute is honored by every caller

- **WHEN** `/notify mute 1h` is set and any harness caller fires `say_notify`
- **THEN** nothing is spoken and the attempt is recorded with outcome `muted`

#### Scenario: Muted is a closed history outcome

- **WHEN** an active mute suppresses a valid notification attempt
- **THEN** Herald appends exactly one `muted` record without synthesizing or transporting audio

#### Scenario: Round-trip test produces evidence

- **WHEN** `/notify test` runs
- **THEN** a fixed phrase is spoken (`--wait`) and the resulting history record is printed

### Requirement: Caller helper ships with the plugin

`say_notify` SHALL be provided by the herald plugin's lib and preloaded in cc via
BASH_ENV; no harness repo SHALL carry its own copy of the helper.

#### Scenario: Preload intact after the move

- **WHEN** a non-interactive cc bash shell starts
- **THEN** `say_notify` resolves as a function with no explicit source line in the caller
