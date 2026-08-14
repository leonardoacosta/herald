# Tasks — orchestration-reliability-controls

Workflow/documentation change only. No code, no service artifacts. Every task's output is
markdown under this change directory or (at archive) `openspec/specs/`.

## 1. Contract definition

- [x] 1.1 Finalize the ID conventions (dispatch `<slug>-D<n>`, attempt `-A<n>`, blocker
      `-BLK<n>`) and the closed terminal-status vocabulary
      (`completed | failed | blocked | abandoned`).
  - Verify: proposal.md, spec delta, and templates use identical vocabulary; grep finds no
    other status words used as terminals.
- [x] 1.2 Write the completion-envelope field contract (required fields, when `blockers`
      and `follow_ups` are required, what counts as an evidence reference).
  - Verify: spec delta scenario shows one valid envelope and one rejected (missing
    evidence) envelope.
- [x] 1.3 Write the phase-gate contract: exploration authority, execution authority, gate
      decision record shape, default-deny.
  - Verify: spec delta contains a scenario where execution without a recorded gate is
    identified as a breach.

## 2. Templates and worked example

- [x] 2.1 Add `design/dispatch-log-template.md` covering dispatch section, attempt list,
      envelope block, blocker record, and gate decision line.
  - Verify: template contains every artifact named in proposal.md § Artifacts.
- [x] 2.2 Add `design/worked-example.md`: one dispatch with two attempts (first
      `abandoned`, second `completed`), one raised-and-resolved blocker, one gate decision,
      all cross-referenced by ID.
  - Verify: every ID referenced in the example resolves within the example (no dangling
    references); acceptance criterion 2 satisfied.
- [x] 2.3 Demonstrate duplicate detection: append an injected second non-terminal dispatch
      for the same task to the example and record the grep-level scan that flags it.
  - Verify: the scan command and its output are captured in the example; acceptance
    criterion 3 satisfied.

## 3. Spec delta

- [x] 3.1 Author `specs/orchestration-reliability/spec.md` (ADDED) with six requirements —
      dispatch/attempt identity, completion envelopes, duplicate prevention, phase gates,
      structured blockers, evidence-gated closeout — each with at least one scenario.
  - Verify: `openspec validate 2026-08-14-orchestration-reliability-controls` passes;
    acceptance criterion 1 satisfied.
- [x] 3.2 Cross-check the Failure recovery section maps to all six controls.
  - Verify: a table in the spec delta or design doc pairs each control with its recovery
    path; acceptance criterion 4 satisfied.

## 4. Adoption and closeout

- [x] 4.1 Record the adoption rule: the next change executed in this repo after approval
      carries a dispatch log and closes out under the contract.
  - Verify: the rule appears in the spec delta as a requirement scenario; measured at that
    change's archive review (acceptance criterion 5).
- [x] 4.2 Confirm zero code impact before archive.
  - Verify: `git diff --stat` for this change touches only this change directory and, at
    archive, `openspec/specs/orchestration-reliability/`; acceptance criterion 6 satisfied.
