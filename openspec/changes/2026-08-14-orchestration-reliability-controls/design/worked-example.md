# Worked example — dispatch log for a hypothetical change `fix-spool-drain`

This example satisfies acceptance criteria 2 and 3 of proposal.md: one dispatch with two
attempts (first `abandoned`, second `completed`), one raised-and-resolved blocker, one gate
decision, one completion envelope, all cross-referenced by ID. It then injects a second
non-terminal dispatch for the same task and records the grep-level scan that flags the
duplicate. Finally, it maps each of the six controls to its recovery path (acceptance
criterion 4).

---

## Dispatch: fix-spool-drain-D1

- Task: tasks.md § 1.1 (diagnose and fix spool drainer lock staleness)
- Phase: execution
- Status: completed
- Dispatched: 2026-08-14T10:02Z by coordinator (Leo)

### Gate decisions

- 2026-08-14T10:40Z — exploration→execution approved by Leo; scope: `bin/herald-player.sh`
  and its tests only; evidence relied on: A1's read-only diagnosis showing the stale-lock
  branch never breaking the mkdir lock (transcript excerpt attached to D1-A1 notes).

### Blockers

- **fix-spool-drain-D1-BLK1** — blocked: end-to-end playback verification; dependency:
  playback host (Leo's Mac) was asleep and unreachable over the tailnet; raised:
  2026-08-14T11:05Z; resolution criteria: playback host reachable and a test clip audibly
  plays.
  - Resolution: 2026-08-14T13:20Z — host woke; `bin/notify.sh --wait "test"` played and
    exited 0 (observed by Leo).

### Attempts

- **fix-spool-drain-D1-A1** — started 2026-08-14T10:05Z; terminal: abandoned (see envelope)
- **fix-spool-drain-D1-A2** — started 2026-08-14T10:45Z; terminal: completed (see envelope)

#### Envelope: fix-spool-drain-D1-A1

```
dispatch: fix-spool-drain-D1
attempt: fix-spool-drain-D1-A1
status: abandoned
evidence:
  - git status clean at abandonment (no partial edits to fold in)
  - agent session died mid-exploration; no envelope was produced by the agent, so the
    coordinator terminalized the attempt as abandoned per the recovery contract
blockers: none
follow_ups:
  - re-run the diagnosis in a fresh attempt (became fix-spool-drain-D1-A2)
```

#### Envelope: fix-spool-drain-D1-A2

```
dispatch: fix-spool-drain-D1
attempt: fix-spool-drain-D1-A2
status: completed
evidence:
  - commit 3e9d1c7 (bin/herald-player.sh stale-lock break fix; git show 3e9d1c7 --stat)
  - tests/player-lock.test.sh — observed "ok 6 tests" on 2026-08-14T13:15Z
  - bin/notify.sh --wait "test" — exit 0, clip audible (resolves BLK1)
blockers: none
follow_ups: none
```

---

## Duplicate-detection demonstration (acceptance criterion 3)

Injected breach: a second dispatch for the same task, minted while D1 was still
non-terminal (as would happen if a coordinator restarted and re-dispatched without
reconciling).

## Dispatch: fix-spool-drain-D2  <!-- INJECTED DUPLICATE, for the scan demo -->

- Task: tasks.md § 1.1 (diagnose and fix spool drainer lock staleness)
- Phase: exploration
- Status: open
- Dispatched: 2026-08-14T11:00Z by coordinator (restarted session)

### Scan

A grep-level scan over the log flags two dispatches sharing one task reference where at
least one is non-terminal:

```
$ grep -A2 '^## Dispatch:' dispatch-log.md | grep 'Task:' | sort | uniq -c | sort -rn
      2 - Task: tasks.md § 1.1 (diagnose and fix spool drainer lock staleness)
```

Any count > 1 requires checking the `Status:` lines of the matching dispatches:

```
$ grep -E '^(## Dispatch:|- Status:)' dispatch-log.md
## Dispatch: fix-spool-drain-D1
- Status: completed
## Dispatch: fix-spool-drain-D2
- Status: open
```

D2 is non-terminal (`open`) for a task D1 also covers → duplicate-control breach.
Resolution per the contract: D2 is terminalized `abandoned` with a cross-reference to D1,
and the breach itself is noted in the log as a control failure.

(The scan above was executed against this file's own dispatch sections; output shown is
the observed output, with the file's other occurrences of the header pattern excluded by
running the scan on the extracted example log.)

---

## Control → recovery path mapping (acceptance criterion 4)

| # | Control | Recovery path (proposal.md § Failure recovery) |
|---|---------|-----------------------------------------------|
| 1 | Dispatch/attempt identity | Coordinator crash/restart: dispatch log is the source of truth; reconcile every non-terminal dispatch before re-dispatch. |
| 2 | Completion envelopes | Agent dies mid-attempt: no envelope means not complete; terminalize `abandoned`, open a new attempt, assess partial work against git evidence. |
| 3 | Duplicate prevention | Duplicate discovered after the fact: terminalize the later dispatch `abandoned` with a cross-reference; fold its evidence into the survivor; record the control failure. |
| 4 | Phase gates | Ungated execution discovered: no closeout until the breach is recorded and adjudicated (spec scenario "Ungated execution is a breach"). Prevention needs no crash recovery beyond that. |
| 5 | Structured blockers | Blocker resolution never arrives: blocked dispatches surface at every review; staleness is surfaced, never garbage-collected; closure requires an explicit abandonment decision. |
| 6 | Evidence-gated closeout | Envelope contradicts evidence: closeout refused, attempt re-terminalized `failed`, discrepancy recorded. |
