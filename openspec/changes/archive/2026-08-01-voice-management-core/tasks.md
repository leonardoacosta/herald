# Tasks — voice-management-core

Path-renamed carry-over of `add-notify-voice-management` sections 1, 2, 4.2
(herdr-shepherd `531863a`). TDD order preserved from the source.

## 1. Read model, catalog, audition

- [x] 1.1 Failing tests: effective-voice view model (configured project, unknown/empty,
      override, default, built-in, blank override, qualified + legacy bare values).
- [x] 1.2 Implement in `pkg/notify` wrapping `Resolve` (precedence untouched); expose
      stored value, effective value, source.
- [x] 1.3 Failing HTTP-fixture tests: catalog parsing, malformed/non-200/unreachable,
      duplicate/empty IDs.
- [x] 1.4 Catalog client + validation for `kokoro:<id>` selections; blend expressions
      validate per component voice. Read/resolve never requires the catalog.
- [x] 1.5 Failing tests: fixed-sample audition — correct endpoint/voice, non-empty audio,
      server failure, and proof of no voice-state write and no history append.
- [x] 1.6 Implement bounded audition reusing the configured base URL + timeout model.

## 2. Persistence and registry

- [x] 2.1 Failing tests: add/replace/remove mutations, default + unrelated-mapping
      preservation, qualified output, legacy bare-value preservation.
- [x] 2.2 Atomic `WriteVoices`: same-dir temp, 0600, sync, rename; write/rename failure
      leaves prior file readable (tested).
- [x] 2.3 Canonical project-code reader sharing `bin/lib.sh` precedence; TOML fixtures
      for valid/duplicate/missing-path/unavailable cases.
- [x] 2.4 `herald notify` read/manage subcommands, stable JSON/line stdout, argument
      validation tests. No arbitrary-text synthesis.

## 3. Cross-repo reconciliation

- [x] 3.1 herdr-shepherd: slim `add-notify-voice-management` to dock-UI + docs only,
      Impact table rows for pkg/notify replaced by "consumes herald notify CLI seams";
      note supersession pointer to this change. (Executed in herdr-shepherd local-only
      commit `87596f09645dd4a5f25a0e2a52a44d978cd7c01d`.)
- [x] 3.2 herald-cc-plugin's `/notify voices` wired to the § 2.4 JSON seam (or a noted
      follow-up if that change already shipped). The still-active plugin task 3.1 now
      requires `herald notify voices --json`; it must not parse `voices.json` directly.

## 4. Acceptance

- [x] 4.1 `go test ./pkg/notify/` green; bash syntax checks on any touched scripts.
- [x] 4.2 Live-Kokoro evidence run: catalog list, audition (no writes), override set →
      `bin/notify.sh -p <project>` resolves it → reset → fallback returns.

## Evidence — 2026-08-01

- Focused Go fixtures cover effective source labeling, catalog parsing and failure
  modes, blend-component validation, fixed-text audition isolation, atomic persistence,
  registry precedence, CLI JSON/line contracts, and argument rejection.
- Shell configuration precedence passed under an isolated home and state directory.
- Live Kokoro acceptance passed against an isolated state directory: catalog contained
  the selected voice; audition created neither state nor history; an override and the
  post-reset built-in fallback were each resolved through `bin/notify.sh` and recorded
  with the expected provider-qualified voice.
