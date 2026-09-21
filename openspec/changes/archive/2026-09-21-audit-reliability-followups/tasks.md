# Tasks

- [x] 1. Repair retired-hook tests/docs and isolate deployment configuration in verification.
- [x] 2. Capture playback destination, make stop confirmation truthful, and test routing/idempotence.
- [x] 3. Wire bounded production queue shutdown and verify SIGTERM with accepted backlog.
- [x] 4. Bound HTTP input and tailnet discovery with real socket/process regressions.
- [x] 5. Identify running executable artifacts and verify replacement/idempotence.
- [x] 6. Expose history append failures and verify worker recovery.
- [x] 7. Run canonical verification, Go race tests, review, archive, and commit only this change.

## Final evidence (2026-09-21)
- `./bin/verify.sh`: exit 0, 24.33s, all Go and nine hermetic shell suites passed, including 21 hook assertions.
- `go test -race ./...`: exit 0, notify package 9.439s.
- `go vet ./...` and `git diff --check`: exit 0.
- Shutdown: TestManagedServiceSIGTERM uses real process signal and HTTP acceptance, verifies two unique canceled terminal records.
- Cancellation: TestAcceptedRequestStopUsesCapturedMappedHost, TestDefaultDeliverUsesCapturedDestination, TestCLIStopUsesCapturedHostAndDuplicateIsNoop pass with fake SSH; spool-drainer suite proves unrelated clip survival.
- Input bounds: real socket EOF/body deadline and concurrent health tests; actual stalled tailscale fixture with lower and upper elapsed assertions.
- Identity: TestBuiltArtifactsReportDistinctPublicVersions builds and calls two actual CLI artifacts; replacement cache test preserves old identity.
- Persistence: failed append under unwritable history path increments health counter; next notification succeeds after repair. Rejected append also counted.
- Independent read-only review: no remaining concrete regression in targeted paths after CLI parity follow-up.
- Live playback and deployment not run. Existing process must be refreshed separately through service-sync when deployment is desired.
- Commit scope includes the already-present Go target-routing and shell mapping-validation prerequisites used by cancellation. Existing notify pipe, README, deployment seed edits, and notify_e2e_test.go remain uncommitted. Their authorship is not claimed here.
