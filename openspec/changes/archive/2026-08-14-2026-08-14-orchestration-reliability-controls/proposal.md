# Proposal: Orchestration reliability controls for multi-agent workflow execution

## Change ID

`orchestration-reliability-controls`

## Why

The Herald build retrospective surfaced a class of failures that were not code defects but
orchestration defects: work dispatched to agents without a durable identity, completions
reported as free-form prose that the coordinator could not verify, the same task dispatched
twice under load or after a coordinator restart, agents sliding from exploration into
execution without an explicit gate, external blockers (a host being down, a credential
missing) reported ambiguously and then silently dropped, and changes closed out on the
strength of an agent's assertion rather than checkable evidence.

Each of these was recovered by hand during the Herald effort. None of them is specific to
Herald. This proposal defines the reliability controls as a cross-cutting workflow contract
so that any coordinator (human or agent) running OpenSpec-driven work gets the same
guarantees regardless of which harness or repo the work lands in.

This is a **workflow proposal, not an implementation proposal**. It defines contracts,
artifacts, ownership, and acceptance criteria. Tooling that automates the contracts is a
follow-on change; until then the contracts are satisfied by disciplined use of files and
existing workflow surfaces.

## What Changes

Six controls, each a named requirement in the new `orchestration-reliability` capability:

1. **Durable dispatch and attempt identity.** Every unit of dispatched work carries a
   dispatch ID minted before dispatch and recorded durably (in the change directory, not in
   a chat transcript). Every execution attempt against a dispatch carries an attempt ID.
   Retries are new attempts under the same dispatch, never new dispatches.
2. **Mandatory completion envelopes.** An agent finishing dispatched work returns a
   structured envelope — dispatch ID, attempt ID, terminal status from a closed vocabulary
   (`completed`, `failed`, `blocked`, `abandoned`), evidence references, and follow-ups —
   not prose alone. A completion without an envelope is treated as not completed.
3. **Duplicate-dispatch prevention.** Before dispatching, the coordinator checks the durable
   dispatch record for an existing non-terminal dispatch covering the same work and either
   resumes it or terminalizes it first. Two live dispatches for the same task ID is a
   defect, detectable from the record alone.
4. **Exploration/execution phase gates.** Work is explicitly phased. An exploration dispatch
   grants read/analyze authority only; crossing into execution (editing files, running
   mutating commands, committing) requires a recorded gate decision naming who approved the
   crossing and on what evidence. The default answer at the gate is "stop and report".
5. **Structured external blockers.** A blocker outside the agent's authority (service down,
   missing credential, human decision needed) is recorded as a structured blocker record —
   what is blocked, on whom/what, since when, and what unblocking looks like — attached to
   the dispatch. Blocked dispatches stay visible until explicitly resolved or abandoned;
   they never age out silently.
6. **Evidence-gated closeout.** A change (and each task within it) is closed only against
   evidence that a third party could re-check: command output, test results, file diffs, or
   an explicit recorded waiver naming who waived and why. "Agent said done" is not evidence.

## Ownership boundaries

- **The coordinator owns**: minting dispatch IDs, the dispatch record, duplicate checks,
  phase-gate decisions, blocker resolution or escalation, and closeout judgment.
- **The executing agent owns**: attempt IDs for its own attempts, producing the completion
  envelope, halting at the exploration/execution boundary absent a gate decision, and
  raising blockers in the structured form instead of prose.
- **The repository owns**: the durable artifacts. All records live under the change
  directory (`openspec/changes/<slug>/`) so they survive coordinator restarts, travel with
  the change, and are archived with it. No record lives only in a chat transcript,
  terminal scrollback, or coordinator memory.
- **Out of every party's scope**: this proposal grants no new execution authority. It only
  constrains how existing authority is exercised and recorded.

## Artifacts and contracts

All artifacts are plain text/markdown in the change directory, hand-writable today and
machine-writable later without a format change:

- `dispatch-log.md` — one section per dispatch: dispatch ID, task reference, phase
  (exploration | execution), current status, and an ordered list of attempts (attempt ID,
  start, terminal envelope reference or "in flight").
- **Completion envelope** — a fenced block appended to the dispatch's section:
  `dispatch`, `attempt`, `status`, `evidence` (paths, commands run with observed results,
  commit SHAs), `blockers` (IDs, if terminalizing as blocked), `follow_ups`.
- **Blocker record** — a labeled entry (`BLK-<n>`) in the dispatch section: description,
  external dependency, raised-at, resolution criteria, and eventual resolution note.
- **Gate decision** — a dated line in the dispatch section: who approved
  exploration→execution, scope granted, and the evidence relied on.
- **Closeout evidence** — tasks.md verification lines reference concrete evidence
  (command + observed result, or artifact path) or an explicit `WAIVED by <who>: <why>`.

ID convention: dispatch IDs are `<slug>-D<n>`, attempts `<dispatch>-A<n>`, blockers
`<dispatch>-BLK<n>`. Opaque, monotonic per scope, never derived from content, never reused.

## Failure recovery

- **Coordinator crash/restart**: the dispatch log is the source of truth. On resume, every
  non-terminal dispatch is reconciled — the agent is queried, or the attempt is
  terminalized as `abandoned` and a new attempt opened. No re-dispatch without reconciling.
- **Agent dies mid-attempt**: the attempt has no envelope, so it is not complete. The
  coordinator terminalizes it as `abandoned` with a note, then opens a new attempt. Partial
  work is assessed against evidence (git state), never assumed.
- **Duplicate discovered after the fact**: the later dispatch is terminalized as
  `abandoned` with a cross-reference; its attempts' evidence is folded into the surviving
  dispatch. The duplication itself is noted as a control failure in the dispatch log.
- **Blocker resolution never arrives**: blocked dispatches appear in every status review
  until resolved or explicitly abandoned with a recorded decision. Staleness is surfaced,
  not garbage-collected.
- **Envelope contradicts evidence** (says `completed`, evidence fails re-check): closeout
  is refused, the attempt is re-terminalized as `failed`, and the discrepancy is recorded.

## Monitoring

Because the record is durable and structured, monitoring is a read-only scan of change
directories, needing no service:

- Non-terminal dispatches older than a working session (staleness).
- Dispatches with >1 non-terminal attempt, or >1 non-terminal dispatch per task
  (duplicate-control breach).
- Execution-phase activity (commits, envelope evidence of mutation) with no recorded gate
  decision.
- Blockers open past their raised-at date with no resolution note.
- Archived changes whose tasks lack evidence or waiver lines.

These checks are runnable by hand (grep) at review time now; automating them is follow-on
work, not part of this change.

## Non-goals

- No new daemon, service, database, or message bus. Files in the change directory only.
- No changes to Herald's runtime code, the notify pipeline, or any `pkg/`, `bin/`,
  `plugin/`, or `compose/` artifact. Herald is the motivating case, not the subject.
- No prescribed harness or agent framework. The contract is harness-neutral.
- No retroactive rewriting of archived changes to the new format.
- No automation of the monitoring scans or envelope validation (explicit follow-on).
- No change to the fail-soft contract or any other existing Herald spec requirement.

## Dependencies

- The existing OpenSpec workflow (`openspec/AGENTS.md` conventions from `~/dev/cc`) — this
  layers on top of it and changes none of its stages.
- Git as the durable store and evidence substrate (SHAs, diffs).
- No software dependencies. No dependency on any other open change; the two 2026-08-14
  changes are archived.

## Measurable acceptance criteria

1. The `orchestration-reliability` spec exists with all six requirements, each with at
   least one scenario, and passes `openspec validate`.
2. A worked example dispatch log (template + one filled example in this change's
   `design/` or the spec's scenarios) demonstrates: two attempts under one dispatch, one
   blocker raised and resolved, one gate decision, and one completion envelope — all
   cross-referencing by ID with no dangling references.
3. Duplicate detection is demonstrable from the record alone: given the example log plus an
   injected second non-terminal dispatch for the same task, a grep-level scan identifies it.
4. Every control has a documented recovery path (the Failure recovery section maps 1:1 to
   the six controls or states why a control needs none).
5. The next change executed in this repo after approval uses the contract end to end: its
   dispatch log exists, every attempt terminalizes with an envelope, and closeout cites
   evidence for every task. (Measured at that change's archive review.)
6. Zero modifications to code paths: `git diff` for this change touches only
   `openspec/changes/2026-08-14-orchestration-reliability-controls/` and, at archive time,
   `openspec/specs/orchestration-reliability/`.

## Impact

- New capability spec: `orchestration-reliability` (delta in this change).
- No modified specs. `notify-pipeline` is untouched.
- No code, no config, no deployed artifacts.
