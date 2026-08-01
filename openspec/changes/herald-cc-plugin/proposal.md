# Proposal: Package herald as a plugin and rebuild the `/notify` control surface

## Change ID

`herald-cc-plugin`

## Depends on

`extract-notify-pipeline` (the pipe must live here before the plugin can ship it).

## Base commits (STOP on drift)

- cc `c820c42d` — spec drift being fixed, output style, BASH_ENV preload
- herald — HEAD at execution time (record it in the PR)

## Why

Advisor run 2026-07-31: cc's `openspec/specs/notify-command/spec.md` requires a
`commands/notify.md` control command (TTS toggle, per-type overrides, history readout,
dry-run, default send) backed by Nexus HTTP (`localhost:7400`). The file does not exist
and Nexus is retired — the spec describes a dead backend and there is **no live control
surface at all**: no mute, no history readout from a session, no dry-run. History exists
only as `notify.ndjson` rendered by shepherd's `notify-pane.sh`. Separately,
`orchestrator-helpers.sh:339-344` (cc, `skills/orchestrator-patterns/scripts/`)
re-sources `notify.sh` despite the BASH_ENV preload, violating the single-preloaded-
function requirement in cc `openspec/specs/notify-transport/spec.md:6-13`.

Leo's direction: harnesses import notification capability as a plugin from herald rather
than carrying their own copies.

## What Changes

- **`plugin/` in herald**, shaped as an installable CC plugin
  using Claude Code's local marketplace shape: `.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json`, `commands/`, `hooks/`, `lib/`, and
  `output-styles/`:
  - `plugin/commands/notify.md` — the rebuilt `/notify`:
    - `status` — env sanity (`$HERALD`, pipe executable, Kokoro health URL), mute state
    - `history [n]` — tail herald's `notify.ndjson`, human-rendered
    - `mute [duration]` / `unmute` — writes a mute file in `$HERALD_STATE_DIR` that
      `bin/notify.sh` checks first (new, small: exit 0 + `muted` history outcome)
    - `test` — fixed-phrase `--wait` round trip, reports the history record
    - `voices` — render `voices.json` (read-only here; management UI is
      herdr-shepherd's retargeted `add-notify-voice-management`)
    - default: `/notify <text>` sends it
  - `plugin/lib/notify.sh` — the `say_notify` caller helper, moved from cc
    `scripts/lib/notify.sh` (project detection, `SAY_NOTIFY_TIMEOUT`, exit-0)
  - `plugin/lib/projects-toml.sh` — the helper's adjacent project resolver dependency
  - `plugin/output-styles/tts-summary.md` — moved from cc `output-styles/tts-summary.md`;
    a fail-soft `SessionStart` hook injects it as plugin-owned additional context because
    output-style directories are not a Claude Code plugin component. The same hook exports the
    plugin `bin/` directory through `CLAUDE_ENV_FILE`, giving zsh tool calls a thin
    `say_notify` adapter while Bash keeps the preloaded function.
- **cc afterwards**: imports the herald plugin; `scripts/lib/bash-env.sh:11` sources the
  plugin's lib path; `notify-command` spec rewritten against the herald backend (all Nexus
  references gone); `orch_tts_notify` (orchestrator-helpers.sh:339-344) collapses to a
  bare `say_notify "$message"` call.
- **Mute semantics**: mute is a herald-side state file so it holds across all harnesses
  and callers, not a cc env var. `muted` is the fifth closed history outcome.

## Non-goals / out of scope

- Voice management UI (stays with `add-notify-voice-management`, retargeted).
- No new notification call sites; the single-emitter rule for blocking-ask attention
  events (cc `notify-command` spec § Blocker Attention Notify) is untouched.
- codex/pi speech wiring — those harnesses get moshi coverage via `moshi-hook-parity`;
  speech-from-codex/pi is future work, not this change.

## Exemplars

- Plugin package shape: Claude Code `.claude-plugin/plugin.json` plus a local marketplace
  manifest; matching plugin and command names preserve the `/notify` command spelling.
- Command file format + frontmatter: cc `commands/p2p.md` frontmatter block (name,
  description, context, effort, model).
- Mute-file check pattern: `bin/notify.sh`'s existing precondition probes (herald
  `bin/notify.sh` after extraction) — one `[ -f ]` check, one history outcome.

## Definition of Done

- **Mechanical**: `/notify status|history|test` run in a cc session produce output; the
  notify-command spec grep gates (its own Scenarios) pass against the rewritten spec;
  cc-side `grep -rn "7400\|NEXUS_URL" commands/ openspec/specs/notify-command/` is clean.
- **Behavior**: `/notify mute 1h` silences a `say_notify` call (history shows `muted`);
  `/notify test` speaks and reports its own history record.
- **Done-when**: proposal archived; cc `output-styles/tts-summary.md` and
  `scripts/lib/notify.sh` are deletions in cc's tree (owned by the plugin);
  `orch_tts_notify` body is a bare `say_notify`.

## Test plan

Shell smoke tests in herald `tests/` (pattern: herdr-shepherd `tests/` harness): mute file
present → exit 0 + `muted` record, no ssh spawned; absent → normal path. Command file is
prose-executed by the harness; its DoD scenarios are the test.

## STOP conditions

- Drift at cited cc lines.
- Claude Code rejects the local marketplace or plugin manifests during validation.
