# Proposal: Native Jcode visibility and integration for Herald

## Change ID

`jcode-native-integration`

## Depends on

None (builds on archived `herald-cc-plugin`, `notify-service`, `warm-playback` — all shipped).

## Base commits (STOP on drift)

- herald — HEAD at execution time (record in the PR)
- Jcode hook contract as documented in the bundled `docs/HOOKS.md` of Jcode
  v0.75.x (`turn_end`, `session_start`, `session_end`, `pre_tool`, `post_tool`,
  `JCODE_HOOK_*` env vocabulary). STOP if the observer-hook env vocabulary
  changes shape before execution.

## Why

Herald's doctrine says harnesses import notification capability from herald rather than
carrying their own copies. Today that holds for claude/cc (the `plugin/` CC plugin), codex
(`hooks.json` → `moshi-hook`), and pi (vendor-managed extension). Jcode is the missing
harness:

- **No attention events.** A Jcode turn finishing, erroring, or a session ending produces
  no spoken notification and no history record, while the same event in cc does. Jcode's
  `[hooks]` table in `~/.jcode/config.toml` currently wires only `jcode-herdr-agent-state.sh`
  (herdr pane state), not herald.
- **No control surface.** From inside a Jcode session there is no `/notify`-equivalent:
  no mute, no history tail, no test round-trip, no voice readout. Operators fall back to
  raw `$HERALD/bin/notify.sh` calls, which works but is undiscoverable and undocumented
  as the Jcode-facing seam.
- **No documented wiring.** `docs/` (per-harness wiring) and `openspec/project.md`'s
  external-seams table do not mention Jcode at all, so drift is undetectable — exactly the
  gap the deferred `moshi-hook-parity` change identified for codex/pi.

Jcode exposes a clean, stable integration surface for this: config-driven lifecycle hooks
(`turn_end`, `session_start`, `session_end` as detached fire-and-forget observers with a
recursion guard), a documented env payload (`JCODE_HOOK_EVENT`, `JCODE_HOOK_SESSION_ID`,
`JCODE_HOOK_STATUS`, `JCODE_HOOK_LAST_ASSISTANT_TEXT`, JSON `JCODE_HOOK_PAYLOAD`), and
per-project skills/commands. The observer hooks are already fail-soft by construction
(spawned detached, failures only logged), which matches herald's contract exactly.

## What Changes

### 1. `plugin/jcode/` — Jcode adapter, sibling of the CC plugin surface

A small adapter directory, not a parallel speech implementation:

- **`plugin/jcode/hooks/turn-end.sh`** — the observer hook target for Jcode's `turn_end`.
  Reads `JCODE_HOOK_STATUS`, `JCODE_HOOK_DURATION_MS`, and
  `JCODE_HOOK_LAST_ASSISTANT_TEXT`, applies a minimum-duration threshold
  (`HERALD_JCODE_MIN_TURN_MS`, default 30000) so trivial turns stay silent, derives a
  short spoken summary line (project name + ok/error), and delegates to
  `$HERALD/bin/notify.sh` — the one pipe. Exits 0 on every path, bounded, per the
  fail-soft contract. Because `bin/notify.sh` posts to the notify service first, the
  hook inherits the async `202` path and never blocks (observer hooks are detached
  anyway, so this is belt-and-braces, not a requirement on Jcode).
- **`plugin/jcode/hooks/session-end.sh`** — optional session-close notification, default
  **off** (`HERALD_JCODE_SESSION_END=1` to enable), because Jcode sessions open and close
  far more often than cc sessions and the default must not be noisy.
- **`plugin/jcode/install.sh`** — idempotent installer that adds/refreshes the herald
  entries in `~/.jcode/config.toml`'s `[hooks]` table **as additional array entries**,
  preserving the existing `jcode-herdr-agent-state.sh` wiring (Jcode accepts hook lists;
  see `docs/HERDR.md`). `--remove` drops only herald's entries. `--status` reports what
  is wired vs. what this repo ships. The installer OWNS these config lines the same way
  `moshi-hook install` owns its entries elsewhere — hand-edits are a defect (lesson from
  the deferred `moshi-hook-parity` findings, item 4).

Herald does not add a `pre_tool` gate. Gating is policy, not attention, and out of scope.

### 2. `/notify` visibility inside Jcode sessions

Jcode already loads `AGENTS.md` and repo skills. Rather than porting the CC plugin
command format:

- **`docs/jcode.md`** — the per-harness wiring doc (parallel to the existing per-harness
  docs): hook table entries, env knobs, the `herald notify` CLI subcommands an agent or
  operator uses from a Jcode session (`status`, `history`, `mute`/`unmute`, `test`,
  `voices`), and the recursion-guard note (`JCODE_HOOKS_DISABLED=1` means hook scripts may
  safely shell out to `jcode` CLI without loops — and conversely, herald's hook must not
  assume a TTY).
- The control surface itself is the existing `herald notify …` CLI. **No new commands,
  no new Go surface** — this change only documents and exposes what exists. If a gap is
  found (e.g. no `herald notify mute` subcommand parity with the CC `/notify mute`),
  record it as a follow-up, do not grow scope here.

### 3. Doctrine and inventory updates

- `openspec/project.md` external-seams table gains a Jcode row.
- The parity matrix intent from `moshi-hook-parity` gets its Jcode column recorded in
  `docs/jcode.md`: which Jcode events exist, which herald wires, which are platform
  limits (Jcode has no ask/permission observer event today — that is a platform limit,
  recorded, not a task).

## Boundaries / Non-goals

- **No mobile push changes.** Moshi wiring for Jcode, if ever, is a separate change owned
  by `moshi-hook install --target jcode` upstream, not hand-wired here.
- **No briefings from hooks.** `say_brief` stays explicit-only; `turn_end` uses
  `say_notify` semantics only.
- **No new speech path, no new transport, no Go changes.** The adapter is shell that
  delegates to `bin/notify.sh`.
- **No `pre_tool`/`post_tool` wiring.** Attention channel only.
- **No editing Jcode itself** (`~/.jcode/source`). Herald consumes the documented hook
  contract; if the contract is insufficient, that is a Jcode feature request, not a
  herald patch.
- **No scheduling/ambient integration** (Jcode ScheduleWakeup, ambient sessions).

## Runtime assumptions

- Jcode ≥ v0.75.x hook contract: observer hooks detached, env vocabulary as above,
  config hot-reloaded (no Jcode restart needed after install).
- No OAuth or credentials anywhere in this seam: Jcode hooks are local process spawns;
  herald's service bind posture (loopback + tailnet) is the access control, unchanged.
- The notify service may be down; the hook inherits `bin/notify.sh`'s fallback guarantee
  unchanged.
- Hook scripts run with the session working directory as cwd and must not depend on it.

## Acceptance evidence

1. **Hook fires end-to-end**: with the installer applied, a real Jcode turn exceeding the
   threshold produces exactly one new history record (`delivered` or a failure outcome)
   in `notify.ndjson`, and `JCODE_HOOK_PAYLOAD` fields appear in the spoken summary
   inputs. Captured via `bin/notify.sh --wait` equivalence or history diff.
2. **Fail-soft proven**: with `HERALD` unset or the pipe missing, the hook exits 0 and
   Jcode logs no hook error affecting the turn (observer semantics verified by running
   the script standalone with a synthetic env).
3. **Installer idempotence**: running `install.sh` twice yields byte-identical
   `config.toml`; `--remove` restores the pre-install `[hooks]` entries exactly,
   preserving the herdr wiring.
4. **Threshold respected**: a sub-threshold synthetic invocation produces no history
   record and no speech.
5. **Docs**: `docs/jcode.md` exists with the parity matrix; `project.md` seams table
   updated.

## Dependencies

- Existing shipped herald surfaces: `bin/notify.sh`, notify service, history store.
- Jcode installed with the documented hook contract (assumption above).
- No cc / codex / pi changes.

## Impact

- New: `plugin/jcode/hooks/turn-end.sh`, `plugin/jcode/hooks/session-end.sh`,
  `plugin/jcode/install.sh`, `docs/jcode.md`, `tests/jcode-hooks.test.sh`
- Modified: `openspec/project.md` (seams table)
- Spec delta: `openspec/specs/notify-pipeline` gains a harness-adapter requirement
  (see `specs/notify-pipeline/spec.md` in this change)
