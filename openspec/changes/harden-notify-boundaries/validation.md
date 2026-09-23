# Validation

## Proposal validation, 2026-09-23

Status: ready for implementation approval, not implemented.

- Refreshed source inspection at `8c192d6` confirmed the five audit surfaces remain unchanged.
- Read repository and personal-organization instructions. The referenced external
  `~/dev/cc/openspec/AGENTS.md` is absent. Used local conventions and existing proposals.
- A local Python structural check passed: five distinct requirement IDs H01–H05,
  fourteen scenarios each containing WHEN/THEN, eight pending tasks with dependencies
  referencing earlier tasks, all five requirements referenced in proposal/tasks, existing
  source and dependent-change paths, and explicit approval boundary.
- `git diff --check` passed before staging. Final staged whitespace validation is required
  before committing these new artifacts.
- Reviewed scope against `talk-to-me-attention` T01. No ledger, retention, recovery, or
  phone-channel implementation is included. Shared-file changes require reconciliation.
- No runtime code, tests, deployed binary, operator configuration, or service changed.
- Prior audit ran `go test -race ./...` and `go vet ./...` successfully. Those checks are
  baseline evidence only, not validation of unimplemented behavior. They were not rerun
  for this documentation-only proposal.

This is a repository-local structural/semantic review, not a claim that an external
OpenSpec CLI validator ran. No external validator was installed.

## Implementation evidence to collect

| Requirement | Required evidence | Current state |
| --- | --- | --- |
| H01 | Public subprocess option matrix, watchdog/exit/side-effect assertions | Pending approval |
| H02 | Fresh artifact, sentinel preservation, standalone/invalid override/signal checks | Pending approval |
| H03 | Shared shell/Go cases and real HTTP/fake-SSH destination/cancellation assertions | Pending approval |
| H04 | Baseline/comparison benchmarks, retained-memory evidence, compatibility cases or justified no-change decision | Pending approval |
| H05 | README links, statuses, timing and grammar checked against implementation | Pending approval |

All tasks remain unchecked. No live notification or deployment acceptance is implied.
