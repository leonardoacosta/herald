# Spec delta: notify-pipeline (jcode-native-integration)

## ADDED Requirements

### Requirement: Jcode consumes the pipe through a herald-owned adapter

Herald SHALL ship a Jcode harness adapter (`plugin/jcode/`) whose hook scripts delegate
exclusively to `$HERALD/bin/notify.sh`, exit 0 on every path, and are wired only through
the herald installer (`plugin/jcode/install.sh`), which owns herald's entries in Jcode's
`[hooks]` config table and preserves all non-herald entries.

#### Scenario: Turn end above threshold

- **WHEN** Jcode fires `turn_end` with a duration at or above `HERALD_JCODE_MIN_TURN_MS`
- **THEN** the adapter delegates one notification to `bin/notify.sh` and exactly one
  history record is appended for the attempt

#### Scenario: Turn end below threshold

- **WHEN** Jcode fires `turn_end` with a duration below the threshold
- **THEN** the adapter exits 0 with no notification and no history record

#### Scenario: Herald absent

- **WHEN** the hook runs with `$HERALD` unset or the pipe missing
- **THEN** the adapter exits 0 silently and the Jcode turn is unaffected

#### Scenario: Installer idempotence

- **WHEN** `install.sh` runs twice against the same config
- **THEN** the resulting `config.toml` is byte-identical, and `--remove` restores the
  pre-install `[hooks]` entries exactly
