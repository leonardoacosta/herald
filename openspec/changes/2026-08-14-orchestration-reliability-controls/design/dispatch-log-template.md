# Dispatch log template

Copy this file to `openspec/changes/<slug>/dispatch-log.md` and fill one section per
dispatch. All records are plain markdown; hand-writable now, machine-writable later
without a format change.

## ID conventions

- Dispatch: `<slug>-D<n>` (minted by the coordinator BEFORE dispatch, monotonic per change)
- Attempt: `<dispatch>-A<n>` (minted by the executing agent, monotonic per dispatch)
- Blocker: `<dispatch>-BLK<n>` (monotonic per dispatch)
- Terminal statuses (closed vocabulary): `completed | failed | blocked | abandoned`
- IDs are opaque, never derived from content, never reused.

---

## Dispatch: <slug>-D1

- Task: <tasks.md reference, e.g. "tasks.md § 2.1">
- Phase: exploration | execution
- Status: open | completed | failed | blocked | abandoned
- Dispatched: <ISO date> by <coordinator>

### Gate decisions

<!-- Required before any execution-phase activity. Default is stop and report. -->
- <ISO date> — exploration→execution approved by <who>; scope: <what may be mutated>;
  evidence relied on: <what made the crossing safe>

### Blockers

<!-- One labeled entry per external blocker. Never deleted; resolved with a note. -->
- **<slug>-D1-BLK1** — blocked: <what>; dependency: <on whom/what>; raised: <ISO date>;
  resolution criteria: <what unblocking looks like>
  - Resolution: <ISO date> — <how it resolved, or "abandoned by <who>: <why>">

### Attempts

- **<slug>-D1-A1** — started <ISO date>; terminal: <status> (see envelope) | in flight

#### Envelope: <slug>-D1-A1

```
dispatch: <slug>-D1
attempt: <slug>-D1-A1
status: completed | failed | blocked | abandoned
evidence:
  - <path, commit SHA, or command + observed result>
blockers: <blocker IDs if status is blocked, else "none">
follow_ups: <list or "none">
```
