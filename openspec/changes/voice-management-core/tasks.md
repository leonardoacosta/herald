# Tasks — voice-management-core

Path-renamed carry-over of `add-notify-voice-management` sections 1, 2, 4.2
(herdr-shepherd `531863a`). TDD order preserved from the source.

## 1. Read model, catalog, audition

- [ ] 1.1 Failing tests: effective-voice view model (configured project, unknown/empty,
      override, default, built-in, blank override, qualified + legacy bare values).
- [ ] 1.2 Implement in `pkg/notify` wrapping `Resolve` (precedence untouched); expose
      stored value, effective value, source.
- [ ] 1.3 Failing HTTP-fixture tests: catalog parsing, malformed/non-200/unreachable,
      duplicate/empty IDs.
- [ ] 1.4 Catalog client + validation for `kokoro:<id>` selections; blend expressions
      validate per component voice. Read/resolve never requires the catalog.
- [ ] 1.5 Failing tests: fixed-sample audition — correct endpoint/voice, non-empty audio,
      server failure, and proof of no voice-state write and no history append.
- [ ] 1.6 Implement bounded audition reusing the configured base URL + timeout model.

## 2. Persistence and registry

- [ ] 2.1 Failing tests: add/replace/remove mutations, default + unrelated-mapping
      preservation, qualified output, legacy bare-value preservation.
- [ ] 2.2 Atomic `WriteVoices`: same-dir temp, 0600, sync, rename; write/rename failure
      leaves prior file readable (tested).
- [ ] 2.3 Canonical project-code reader sharing `bin/lib.sh` precedence; TOML fixtures
      for valid/duplicate/missing-path/unavailable cases.
- [ ] 2.4 `herald notify` read/manage subcommands, stable JSON/line stdout, argument
      validation tests. No arbitrary-text synthesis.

## 3. Cross-repo reconciliation

- [x] 3.1 herdr-shepherd: slim `add-notify-voice-management` to dock-UI + docs only,
      Impact table rows for pkg/notify replaced by "consumes herald notify CLI seams";
      note supersession pointer to this change. (Executed in herdr-shepherd local-only
      commit `87596f09645dd4a5f25a0e2a52a44d978cd7c01d`.)
- [ ] 3.2 herald-cc-plugin's `/notify voices` wired to the § 2.4 JSON seam (or a noted
      follow-up if that change already shipped).

## 4. Acceptance

- [ ] 4.1 `go test ./pkg/notify/` green; bash syntax checks on any touched scripts.
- [ ] 4.2 Live-Kokoro evidence run: catalog list, audition (no writes), override set →
      `bin/notify.sh -p <project>` resolves it → reset → fallback returns.
