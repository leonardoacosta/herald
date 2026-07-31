# Proposal: Moshi hook parity and doctrine across claude, codex, and pi

## Change ID

`moshi-hook-parity`

## Base commits (STOP on drift)

- cc `c820c42d` — `settings.json` moshi wiring
- codex `f665ca7` — `hooks.json`
- pi `b50cc8e` — `agent/extensions/moshi-hooks.ts` (vendor-managed, read for contract only)

## Why

Advisor run 2026-07-31. Moshi (getmoshi.app — mobile inbox, Live Activities, Watch
approvals for agent fleets) is wired into all three harnesses, but coverage is uneven and
undocumented, and no repo owns the doctrine:

- **claude (cc `settings.json`)**: 9 wirings — PermissionRequest, Pre/PostToolUse for
  AskUserQuestion and ExitPlanMode, SessionStart/End, Stop, UserPromptSubmit.
- **codex (`hooks.json`)**: 4 — PermissionRequest, SessionStart, Stop, UserPromptSubmit.
  No ask/plan events, no SessionEnd.
- **pi (`agent/extensions/moshi-hooks.ts`)**: 5 lifecycle events (SessionStart,
  UserPromptSubmit, AgentStart, AgentEnd via agent_settled, SessionEnd). Ask-user
  attention was bridged separately (archived pi change
  `bridge-pi-ask-user-attention-signals`, 2026-07-29) — verify what actually reaches
  moshi-hook today before assuming a gap.

Consequences: a codex session waiting on a question can look identical to one still
working on the phone (the exact defect the pi bridge fixed); nobody can say which events
each harness is *supposed* to send; and the wiring is duplicated per-harness with no
inventory to check against.

## What Changes

- **Inventory first** (task 1): build the actual event matrix per harness — what fires,
  what payload fields (session_id, transcript_path, last_assistant_message,
  context_remaining), what Moshi does with each (inbox / Live Activity / approval).
  Verify against getmoshi.app/docs/hooks for the event vocabulary Moshi understands and
  against each harness's supported hook types (codex may simply not expose ask-level
  hooks — record that as a platform limit, not a task).
- **Close real gaps**: for each event Moshi can render and the harness can emit but isn't
  wired — likely codex SessionEnd, and codex ask/plan attention if its hook surface
  allows — add the wiring in that harness's config, matching the existing entry shape.
- **`docs/attention-channels.md` in herald**: the doctrine — which events each harness
  sends to which channel (speech vs. Moshi vs. history), the single-emitter rule for
  blocking-ask attention (cc `notify-command` spec § Blocker Attention Notify), and the
  parity matrix as a maintained table. Herald owns this doc; harness configs cite it.
- **Enrichment (bounded)**: pi already ships `last_assistant_message` on AgentEnd
  (moshi-hooks.ts:144-147); if claude's Stop wiring can carry the same via moshi-hook's
  claude-hook mode, note it in the matrix — implement only if moshi-hook already
  supports it (it is an external binary; herald does not fork it).

## Non-goals / out of scope

- No changes to the moshi-hook binary itself (external, installed to `~/.local/bin`).
- Never edit pi `agent/extensions/*` (vendor-managed, overwritten on reinstall — pi
  `CLAUDE.md:112-114`); pi-side additions go in sibling extensions per that repo's rule.
- No speech wiring for codex/pi (future work; this change is the mobile channel).

## Exemplars

- Wiring entry shape: cc `settings.json` moshi entries (matcher + command); codex
  `hooks.json:2-52`.
- Sibling-extension pattern for pi: the archived
  `bridge-pi-ask-user-attention-signals` change's implementation.
- Doctrine doc register: cc `skills/deploy-and-env/references/notifications.md` (v4
  reference) — same structure: diagram, contract, debugging checklist.

## Definition of Done

- **Mechanical**: the parity matrix in `docs/attention-channels.md` has a row per event ×
  harness with wired/not-wired/platform-limit status, each cell backed by a config
  `file:line` citation; codex `hooks.json` parses after edits.
- **Behavior**: one evidence event per harness reaches the Moshi inbox (screenshot or
  Moshi history), including at least one blocked-on-question event from codex if its
  platform allows.
- **Done-when**: proposal archived; matrix committed; real gaps either wired or recorded
  as platform limits with the limiting fact cited.

## STOP conditions

- Base-commit drift in any of the three configs.
- moshi-hook's supported event vocabulary (its CLI modes) can't be determined from docs
  or `--help` — report rather than guess payload contracts.
