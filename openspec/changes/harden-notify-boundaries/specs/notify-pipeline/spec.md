## ADDED Requirements

### Requirement: Missing project arguments remain fail-soft (H01)

`say_notify`, `say_brief`, and `bin/notify.sh` SHALL diagnose a missing operand for `-p`
or `--project` and return/exit 0 before invoking a transport. Invalid invocations SHALL
NOT append notification history. Valid parsing and the single speech path SHALL remain
unchanged.

#### Scenario: Trailing option under either caller mode

- **WHEN** each public entry point receives `-p` or `--project` without an operand, alone or after text, under normal Bash or Bash with errexit and nounset
- **THEN** it completes with exit 0 within a two-second test watchdog, without watchdog termination, transport calls, or history writes

#### Scenario: Literal text and valid arguments remain valid

- **WHEN** callers supply a valid project, an explicit empty project, or use `--` before option-looking text
- **THEN** existing project/text semantics are preserved and valid speech delegates exactly once through the existing pipe

### Requirement: Hermetic verification tests a fresh isolated artifact (H02)

The canonical verification gate SHALL build current source into a temporary binary once
and supply it to real-binary shell fixtures. It SHALL NOT execute or replace a pre-existing
deployment binary. Fixtures invoked alone SHALL use an explicitly supplied test binary or
build their own temporary artifact. Invalid explicitly supplied paths SHALL fail tests.

#### Scenario: A stale binary exists

- **WHEN** the gate runs in an isolated checkout containing an executable sentinel at `bin/herald`
- **THEN** the sentinel is neither invoked nor changed, and service and fallback fixture subprocesses use the freshly built temporary binary

#### Scenario: Standalone fixture without deployment binary

- **WHEN** a real-binary fixture runs with no supplied test binary and no `bin/herald`
- **THEN** it builds and uses a temporary artifact without creating `bin/herald`

#### Scenario: Invalid override or interrupted run

- **WHEN** a fixture receives a nonexistent explicit test binary, or the gate is interrupted
- **THEN** the invalid override fails without deployment fallback, and interruption cleans gate-owned temporary artifacts without touching operator state

#### Scenario: Verification stays silent

- **WHEN** the canonical gate runs
- **THEN** it uses isolated fixture state and local fake providers only, and excludes live acceptance, real-interface bind checks, auditions, deployment, and real playback

### Requirement: Client mapping validation agrees with request syntax (H03)

Configured identity keys SHALL match the current request grammar: trimmed ASCII
`[A-Za-z0-9][A-Za-z0-9._-]{0,62}`. A blank map SHALL mean no overrides. A nonblank map
SHALL reject empty entries, duplicate trimmed keys, empty hosts, hosts beginning with `-`,
and whitespace inside hosts. Entries SHALL split on the first equals sign. Shell and Go
validation SHALL agree through shared contract fixtures. Request identities SHALL never
be used directly as SSH hosts.

#### Scenario: Valid boundary identities

- **WHEN** mappings contain valid 1-character or 63-character identities, with surrounding entry whitespace
- **THEN** verification succeeds and valid HTTP requests select the configured destination captured at admission for delivery and cancellation

#### Scenario: Malformed mapping

- **WHEN** a mapping includes a leading-punctuation or 64-character identity, duplicate trimmed key, empty entry (including trailing comma), or invalid host
- **THEN** verification exits nonzero without contacting a host and runtime resolution ignores the entire mapping, reports a bounded diagnostic without raw values, and uses static playback fallback

#### Scenario: Unknown identity, blank mapping, or invalid request

- **WHEN** a syntactically valid request has an unknown/absent identity or a blank map
- **THEN** it uses the configured static playback host
- **AND WHEN** the request target itself violates the identity grammar
- **THEN** the API retains HTTP 400 rejection before synthesis or delivery

### Requirement: History optimization is measured and compatible (H04)

The change SHALL capture synthetic baseline and comparison measurements for status counts
and tail-10 at 1k, 10k, and 100k rows, separating execution time, cumulative allocations,
and retained memory. Optimization SHALL proceed only when full-log retention is confirmed.
If optimized, counting SHALL retain O(1) records and positive-n tails SHALL retain
O(min(n, record count)) records, plus scanner memory. All rows SHALL still be scanned for
corruption. A benchmark-only no-change disposition SHALL explain why optimization was not
justified.

#### Scenario: Large valid history

- **WHEN** count and tail-10 queries read growing synthetic valid logs
- **THEN** results match the baseline exactly, measurements identify retained-memory growth separately from total decoding allocations, and any optimized path meets the retained-record bound

#### Scenario: Empty, missing, and all-record reads

- **WHEN** history is missing, empty, includes blank lines, contains fewer than n records, or n is nonpositive
- **THEN** CLI/HTTP output shapes, ordering, counts, and all-record behavior remain unchanged

#### Scenario: Corrupt or oversized row outside the tail

- **WHEN** a malformed interior row, malformed truncated final row, or scanner-limit violation exists, including before the requested tail
- **THEN** history reads still report an error rather than hiding corruption, and status retains its existing zero-count-on-read-error behavior

### Requirement: Operator guidance reflects actual notification state (H05)

README SHALL distinguish queued acceptance from eventual worker-recorded outcome and
played audio. It SHALL distinguish archived features from active proposals and show active
dependencies and approval status. Verification and identity grammar guidance SHALL match
the implemented behavior.

#### Scenario: Operator investigates a 202 response

- **WHEN** the operator follows the architecture and use documentation
- **THEN** it describes 202 as queue acceptance, does not promise an admission-time durable history record or completed playback, and points to history for the later outcome

#### Scenario: Operator selects next work

- **WHEN** the operator follows README status links
- **THEN** archived work is labeled completed, attention work and its dependent phone experiment link to their actual proposals, and this change is labeled with its current status rather than presumed complete
