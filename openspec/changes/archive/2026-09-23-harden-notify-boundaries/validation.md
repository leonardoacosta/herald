# Validation

## Feature definition

Completed and committed separately as `1e0ef30`, based on `8c192d6`. A local structural check
passed for five requirements, fourteen WHEN/THEN scenarios and eight ordered tasks. The external
`~/dev/cc/openspec/AGENTS.md` was unavailable; repository-local rules and existing proposal
conventions were used. Implementation was approved by the operator's `approve and /apply`
request on 2026-09-23.

## Implementation evidence

| Requirement | Evidence |
| --- | --- |
| H01 | `bash tests/notify-arguments.test.sh` passes. Both public entry points and `say_brief` return 0 for a missing project value, under normal and strict shells, with no history or transport effects. Valid and literal argument cases preserve delegation. |
| H02 | `bash tests/verify-binary-isolation.test.sh` passes in a disposable repository copy. Canonical verification leaves the executable sentinel untouched and uncalled, rejects an invalid override, and standalone fixture builds without creating `bin/herald`. |
| H03 | `bash tests/notify-targets.test.sh` and Go shared-fixture tests pass. The HTTP handler test proves invalid deployment mapping is ignored as a whole and captures/uses the configured static host. `tests/notify-service.test.sh` passes service-up, service-down, and slow-synthesis HTTP cases with local Kokoro stub and fake SSH. |
| H04 | Synthetic comparison measurements are recorded below. Streaming status count and tail preserve ordering, `n<=0`, and corrupt-row detection. CLI/HTTP reject positive `n>100000` before retained-result allocation. |
| H05 | README claims and links checked against handler/worker code, fixture grammar, and existing active/archive proposal paths. |

Final local gates passed on the final runtime snapshot:

- `go test -race ./...`
- `go vet ./...`
- `./bin/verify.sh` including the isolated sentinel and standalone-fixture test
- `bash -n` on changed shell entry points and fixtures
- `git diff --check`

The pre-existing ignored `bin/herald` was present and left unchanged. No service restart,
operator config edit, remote SSH, live synthesis or audible playback was run. The test suites
use only isolated HOME/state, local fake HTTP synthesis, fake SSH and a disposable repository copy.

## H04 benchmark measurements

Synthetic rows were written to `testing.B.TempDir` before timing. Host: Linux amd64, AMD Ryzen
9 9900X. The implementation commit captured three runs of the full-slice reference path versus
streaming count/tail with `go test ./pkg/notify -run '^$' -bench 'BenchmarkHistory'
-benchmem -count=3`. The earlier proposal-only exploratory timings were not used as pre-change
baseline evidence. The full-slice reference path provides an in-run comparison. Both paths scan
every row, so time and cumulative allocations still scale with file size.

| Rows | Full count B/op | Streaming count B/op | Full tail-10 B/op | Streaming tail-10 B/op |
| ---: | ---: | ---: | ---: | ---: |
| 1k | 557,029 | 226,357 | 557,025 | 227,882 |
| 10k | 7,682,513 | 1,669,857 | 7,683,369 | 1,671,777 |
| 100k | 87,342,094 | 16,104,169 | 87,340,140 | 16,107,241 |

These B/op values are from the earlier one-run directional comparison, not from the three-run
implementation commit gate. They show substantially lower cumulative allocation for the measured
sample, not peak live heap or a stable performance guarantee. Structural bounds come from code and
large-n tests, not memory profiling.

## Scope and remaining boundaries

Tasks T01–T08 are complete. `talk-to-me-attention` T01's durable ledger/retention design remains
separate; no ledger, retention policy, recovery, or phone-channel work was included. This change
is not deployment or live-device acceptance.
