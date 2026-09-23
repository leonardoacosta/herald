# Harden notification boundaries and verification

## Status and authorization

Proposed, awaiting implementation approval. On 2026-09-23 the operator selected all five
ranked audit candidates through `feature`. This authorizes definition of this change,
not implementation, deployment, or live notifications.

Base inspected: `8c192d6`. Existing `.gitignore` modification and `CLAUDE.md` deletion are
unrelated and must remain untouched. The referenced `~/dev/cc/openspec/AGENTS.md` was
unavailable during authoring. This proposal follows Herald's local instructions and
existing proposal/spec/task structure instead.

## Why

1. `plugin/lib/notify.sh:59` and `bin/notify.sh:43` shift two arguments without checking
   availability. A trailing `-p` hangs the helper or exits 1 under caller `set -e`, before
   its timeout wrapper. The audit reproduced both helper failures.
2. Shell tests build `bin/herald` only when absent. A local verification pass can test an
   old executable while Go tests exercise current source, or write a deployment artifact.
3. Shell mapping validation accepts identities the HTTP API rejects. The Go mapping
   resolver does not enforce the verifier's duplicate/host checks.
4. Status and last-N history readouts decode and retain the entire append-only log.
   The code demonstrates unbounded retained records, but no production latency claim has
   been established. Measure before optimizing.
5. README describes admission-time history writes and lists archived changes as pending.
   Operators need the actual async outcome timing and current proposal dependencies.

## Scope and acceptance map

| ID | Improvement | Actors and observable evidence |
| --- | --- | --- |
| H01 | Fail-soft missing project arguments | Shell callers return 0 promptly without transport, including caller errexit |
| H02 | Fresh isolated verification binary | Maintainers and CI test current source without replacing deployed bin/herald |
| H03 | Consistent client mapping grammar | Operators' validated identities work in HTTP requests; invalid maps never select unsafe hosts |
| H04 | Measured history read scaling | Operators retain identical history/status results with benchmark-backed bounded retained records if justified |
| H05 | Accurate operational documentation | Operators can distinguish accepted from completed and find active work versus archives |

## Decisions

### H01: Reject malformed invocation before transport

Check argument count before shifting `-p` or `--project`. A missing value produces a
short diagnostic and exits/returns 0. It is an invalid invocation, not an admitted notify
attempt, so it creates no history record. Preserve existing handling of an explicit empty
value, valid project values, `--` literal text, and `say_brief` delegation. Do not redesign
option parsing or add a parallel speech path.

### H02: A test artifact is not a deployment artifact

The canonical gate builds current source once into its own temporary directory and
exports `HERALD_BIN` for real-binary fixtures and pipe subprocesses. Direct invocations of
those fixtures build their own temporary binary when no test binary was supplied. An
explicit invalid test-binary path fails the fixture rather than falling back to deployment.
Tests deliberately exercising a missing or fake binary may override it inside their case.
Preserve the explicit hermetic allowlist and isolated HOME/config/state. Never add live
acceptance, bind-posture, or audition scripts to that gate. Clean temporary artifacts on
normal exit and signals. Do not restart services or change operational binary resolution.

### H03: Keep the existing API grammar authoritative

After trimming surrounding whitespace, a configured identity is 1–63 ASCII characters,
starts with an alphanumeric character, and otherwise uses alphanumerics, `.`, `_`, `-`.
An empty/whitespace-only mapping means no overrides. Nonempty mappings are comma-separated
identity=host entries, split on the first equals sign. Reject empty entries (including a
trailing comma), duplicate identities after trimming, empty hosts, hosts starting with `-`,
and hosts containing whitespace. Preserve other currently documented SSH alias syntax.

Both the shell verifier and Go resolver consume the same table-driven contract fixtures.
Use small idiomatic parsing helpers, not a new service or framework. The verifier exits
nonzero on invalid configuration without contacting hosts. The runtime treats an invalid
mapping as unavailable in its entirety, emits a bounded diagnostic without dumping values,
and uses the configured static playback host. This avoids order-dependent duplicate
selection while preserving fail-soft delivery. Unknown or absent request identities also
use that static fallback. Invalid request target syntax remains HTTP 400. Never turn a
request field into a raw SSH destination. Capture the chosen destination once at admission
so cancellation still targets the same host.

### H04: Preserve semantics, measure retained memory

First benchmark synthetic 1k, 10k, and 100k-record logs for status counting and tail-10,
with setup outside timing. Record time/op, bytes/op and allocations/op, plus peak live heap
or equivalent evidence of retained records. Total decoding allocations may still scale
with file size even after retained memory is bounded. Do not confuse these metrics.

If baseline profiling confirms full-slice retention, share the scanner/decoder and stream
counts and a bounded tail buffer. Status retains O(1) records and positive-n tails retain
O(min(n, record count)) records, plus the scanner buffer. Continue scanning the whole file
to preserve interior-corruption detection. O(total rows) CPU and cumulative allocations
are acceptable here. Preserve oldest-to-newest result order, missing/empty file behavior,
blank lines, scanner limits, n<=0 returning all records, and errors on malformed rows.
Status continues reporting zero count on a history read error. No retention, rotation,
index, cache, database, repair, or new corruption policy is included.

If baseline evidence does not justify the optimization, deliver benchmarks and a documented
no-change conclusion for H04 instead. Do not invent a speedup or timing threshold.

### H05: Document what exists

Correct README's architecture diagram to show accepted outcomes recorded by the worker,
not guaranteed durably at admission. Explain that 202 means queued, not played, and does
not promise crash recovery. Identify archived core work and link the two existing active
approved proposals in dependency order, plus this proposal with its actual status. Update
verification and target grammar documentation to match H02/H03 once implemented.

## Dependencies and concurrent work

H02 precedes final validation of H01/H03. H04 is independent after baseline characterization.
H05 follows behavior decisions. All five may be implemented under this one change approval.

`talk-to-me-attention` T01 proposes durable event identity, retention and corruption
handling. This change only improves existing notify-history readers. It neither implements
that ledger nor blocks its proposal. Reconcile shared store/status/send edits at execution
start and before integration. If T01 has changed public history semantics, stop and revise
this proposal rather than silently overriding its contract. `phone-speech-experiment`
continues depending on its parent attention-channel tasks, not on this change.

## Impact and non-scope

Expected implementation surfaces: plugin/lib/notify.sh, bin/notify.sh, bin/lib.sh,
bin/verify.sh, bin/verify-targets.sh as needed, pkg/notify delivery/send/store/status helpers,
related Go and hermetic shell tests, shared test fixtures, README.md.

No production data migration is needed. Newly rejected malformed target mappings require
an operator to correct the deployment file and restart the service through its existing
workflow. This proposal does not edit that file or perform that restart.

Excluded: general timeout portability, new channels or hooks, service/player lifecycle
changes, fallback eligibility changes, playback routing parity expansion for --wait,
request schema changes, history retention/recovery, dependency upgrades, cosmetic refactors,
and changes to .gitignore or CLAUDE.md.

## Validation and approval

The audit baseline passed `go test -race ./...` and `go vet ./...`; this is not evidence of
future implementation. Tasks define fresh verification through public shell/CLI/HTTP paths
with local fixtures only. Implementation and deployment remain separate: completing this
change does not authorize service-sync, remote SSH, actual synthesis, or audible playback.
