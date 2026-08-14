# orchestration-reliability Specification (delta)

## ADDED Requirements

### Requirement: Dispatched work carries durable dispatch and attempt identity

Every unit of dispatched work SHALL carry a dispatch ID (`<slug>-D<n>`) minted before
dispatch and recorded in the change directory's dispatch log. Every execution attempt SHALL
carry an attempt ID (`<dispatch>-A<n>`). Retries SHALL be new attempts under the existing
dispatch, never new dispatches. IDs are opaque, monotonic per scope, and never reused.

#### Scenario: Retry after a dead attempt

- **WHEN** an attempt ends without a completion envelope and the work is retried
- **THEN** the prior attempt is terminalized `abandoned` and a new attempt ID is opened
  under the same dispatch ID

### Requirement: Completions are reported as structured envelopes

An agent finishing dispatched work SHALL return a completion envelope containing the
dispatch ID, attempt ID, a terminal status from the closed vocabulary
(`completed | failed | blocked | abandoned`), evidence references, and follow-ups. A report
lacking an envelope, or an envelope lacking evidence for a `completed` status, SHALL be
treated as not completed.

#### Scenario: Valid envelope is accepted

- **WHEN** an agent returns an envelope such as:

  ```
  dispatch: herald-notify-D1
  attempt: herald-notify-D1-A2
  status: completed
  evidence:
    - commit 4f2c9ab (git show 4f2c9ab --stat)
    - `go test ./pkg/notify/` — ok, 14 passed, observed 2026-08-14
  blockers: none
  follow_ups: none
  ```

- **THEN** the coordinator accepts the envelope, verifies each evidence reference is
  re-checkable, and terminalizes the attempt `completed`

#### Scenario: Prose-only or evidence-free completion is rejected

- **WHEN** an agent reports "done" without an envelope, or with an envelope such as:

  ```
  dispatch: herald-notify-D1
  attempt: herald-notify-D1-A2
  status: completed
  evidence: (none)
  ```

- **THEN** the coordinator refuses closeout and the attempt remains non-terminal until an
  envelope with re-checkable evidence (or a `failed`/`abandoned` terminalization) is recorded

### Requirement: Duplicate dispatches are prevented from the durable record

Before dispatching, the coordinator SHALL check the dispatch log for an existing
non-terminal dispatch covering the same task and either resume it or terminalize it first.
Two non-terminal dispatches for one task SHALL be detectable from the record alone and
treated as a control breach.

#### Scenario: Coordinator restart does not re-dispatch

- **WHEN** a coordinator resumes after a crash and finds a non-terminal dispatch for a task
- **THEN** it reconciles that dispatch (query the agent, or terminalize `abandoned`) before
  any new dispatch for the same task is minted

### Requirement: Exploration and execution are separated by a recorded gate

An exploration dispatch SHALL grant read/analyze authority only. Crossing into execution
(editing files, mutating commands, commits) SHALL require a gate decision recorded in the
dispatch log naming who approved, the scope granted, and the evidence relied on. Absent a
recorded gate, the default SHALL be stop and report.

#### Scenario: Ungated execution is a breach

- **WHEN** evidence of mutation (commits, edited files) exists for a dispatch whose log has
  no gate decision
- **THEN** review identifies the dispatch as breaching the phase gate and the work is not
  closed out until the breach is recorded and adjudicated

### Requirement: External blockers are structured and never age out silently

A blocker outside the agent's authority SHALL be recorded as a labeled blocker record
(`<dispatch>-BLK<n>`) stating what is blocked, the external dependency, raised-at time, and
resolution criteria. Blocked dispatches SHALL remain visible in every status review until
explicitly resolved or abandoned with a recorded decision.

#### Scenario: Stale blocker surfaces at review

- **WHEN** a status review runs and a blocker record has no resolution note
- **THEN** the blocker is listed as open regardless of age, and closing the change while it
  is open requires an explicit abandonment decision in the log

### Requirement: Closeout is gated on re-checkable evidence

A change and each task within it SHALL be closed only against evidence a third party can
re-check (command output with observed results, test results, diffs, commit SHAs) or an
explicit recorded waiver naming who waived and why. Agent assertion alone SHALL NOT close
work. Changes executed in this repo after adoption SHALL carry a dispatch log and close out
under this contract.

#### Scenario: Envelope contradicts evidence

- **WHEN** an envelope claims `completed` but its cited evidence fails re-check
- **THEN** closeout is refused, the attempt is re-terminalized `failed`, and the
  discrepancy is recorded in the dispatch log

#### Scenario: Post-adoption changes carry the contract

- **WHEN** a change is executed in this repo after this capability is adopted
- **THEN** its change directory contains a dispatch log, every attempt terminalizes with a
  completion envelope, and its tasks.md verification lines cite concrete evidence
  (command + observed result, or artifact path) or an explicit `WAIVED by <who>: <why>`,
  measured at that change's archive review
