# Ordered implementation tasks

All implementation boxes are pending. Do not begin before proposal approval. IDs are local
references. Preserve unrelated work and reconcile touched paths before each task.

- [ ] T01 [H01–H05] Confirm approval and inspect git status, active changes, and the current
  implementations named in proposal.md. Reconcile any concurrent attention T01 work in
  store/status/send. Record baseline `go test -race ./...` and `go vet ./...`. Do not run
  the old canonical shell gate until artifact isolation is corrected, and do not rebuild
  bin/herald. Stop for changed public history contracts rather than guessing.

- [ ] T02 [H02; depends T01] Update bin/verify.sh and real-binary fixtures
  tests/notify-service.test.sh, tests/notify-brief.test.sh, and
  tests/notify-config-divergence.test.sh to build once in gate-owned temporary storage and
  propagate HERALD_BIN to every service and pipe subprocess. Inspect all allowlisted
  fixtures for direct bin/herald execution. Preserve intentional fake/missing binary cases.
  Standalone fixtures build temporary artifacts only when no override is supplied. Add a
  hermetic verification test using an isolated repository copy with a sentinel bin/herald
  that logs/fails if invoked. Assert its bytes are unchanged, no invocation occurred,
  fresh binary use on service and fallback paths, invalid override failure, standalone
  absence behavior, and signal cleanup. Avoid recursive invocation of that test by the
  gate it is testing. Register the test in the allowlist only with a bounded nonrecursive
  harness. Run the three fixtures standalone and ./bin/verify.sh. Expect exit 0, no real
  service/provider contacts, and no deployment artifact writes.

- [ ] T03 [H01; depends T02] Add tests/notify-arguments.test.sh with a subprocess matrix
  for say_notify, say_brief, and bin/notify.sh, both project option spellings, alone and
  after text, under ordinary Bash and `bash -e -u`. Use isolated HOME/config/state and
  stub transports that log unexpected calls. Assert exit 0 before a two-second watchdog,
  diagnostic present, and no history or transport side effects. Include valid/empty
  project values and `--` literal text regression cases. Demonstrate failing cases first,
  guard both parser shifts, then run `bash tests/notify-arguments.test.sh` and the canonical
  gate. Keep say_brief as delegation only. Add the test to the explicit allowlist.

- [ ] T04 [H03; depends T02] Define shared machine-readable mapping cases in
  tests/fixtures/client-targets.json, consumed by tests/notify-targets.test.sh and Go tests.
  Cover blank maps, trim handling, 1/63/64-character keys, leading punctuation, invalid
  characters, duplicates, empty entries/trailing comma, first-equals split, invalid hosts,
  unknown/absent request identities and malformed API targets. Freeze expected outcomes
  before edits. Implement matching small parsers in bin/lib.sh and pkg/notify, reusing
  normalizeNotifyTarget's grammar rather than expanding it. Reject the whole invalid map
  at runtime with a bounded value-free diagnostic and static-host fallback. Preserve
  admission-time destination capture. Verify `bash tests/notify-targets.test.sh`, Go
  delivery/service tests, and the canonical gate. Exercise real HTTP handlers and fake-SSH
  destination capture for valid mapping, invalid-map fallback, unknown identity, and
  cancellation. No fixture may contact a real SSH host. The shell verifier must still
  work without needing an installed Herald binary.

- [ ] T05 [H04; depends T01] Add synthetic history benchmarks in
  pkg/notify/history_benchmark_test.go for count/status and tail-10 at 1k/10k/100k rows.
  Write fixture data outside timing and use bounded synthetic text, never operator logs.
  Run `go test ./pkg/notify -run '^$' -bench 'BenchmarkHistory' -benchmem -count=3` and
  capture retained-memory evidence separately from cumulative B/op. Characterize CLI and
  HTTP shapes and store errors for missing/empty files, blank lines, n<=0, n larger than
  history, ordering, corrupt interior/final rows and oversized rows. Profile and benchmark
  files go in scratch storage, not tracked source or live state. Record methodology and
  baseline observations in this change's validation.md.

- [ ] T06 [H04; depends T05] If baseline confirms full-slice retention, share the existing
  scanner/decoder in store.go and use streaming count and a bounded tail buffer from
  status.go. Allocate according to actual rows, not blindly to an arbitrary caller n.
  Preserve full scans, corruption errors and public shapes. Do not add retention, indexes,
  recovery or caching. Rerun the exact T05 benchmarks/profiles and characterization tests.
  Record retained-record bounds and measured tradeoffs without claiming total allocations
  become constant. If not justified, retain the benchmarks and record an evidence-backed
  no-change disposition instead. Either branch requires fresh tests and a clear H04 verdict.

- [ ] T07 [H05; depends T03,T04,T06] Correct README diagram, verification guidance,
  target grammar and status links. Explain 202 versus worker outcome and played audio,
  without promising crash durability. Replace archived-work-as-pending entries with current
  attention/phone dependency links and this change's actual status. Check links against
  files and compare claims with HandleNotify, worker recording, verify.sh and the shared
  grammar fixtures. Do not update unrelated historical specs or rewrite doctrine.

- [ ] T08 [H01–H05; depends T07] Run ./bin/verify.sh, `go test -race ./...`,
  `go vet ./...`, shell syntax checks for changed scripts, and `git diff --check`.
  Re-run T02 artifact-provenance checks and T05/T06 measurements. Map every spec scenario
  to an observed command/result in validation.md, including no-optimization disposition
  if applicable. Verify bin/herald and unrelated dirty files were not changed by checks.
  No live acceptance or deployment is needed or authorized by this change. Mark tasks
  complete only with evidence, then archive through the repository's normal closure
  workflow and repair proposal links as part of archival. Report any blocked scenario
  instead of calling it passed.
