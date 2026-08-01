# Tasks — herald-cc-plugin

## 1. Plugin skeleton

- [ ] 1.1 Create `plugin/.claude-plugin/plugin.json` and `marketplace.json` plus
      commands/, hooks/, lib/, and output-styles/. Use marketplace name `herald`, plugin
      name `notify`, and matching `commands/notify.md` so the command remains `/notify`.
      Verify: JSON parses; Claude validates and imports the local marketplace/plugin.
- [ ] 1.2 Move cc `scripts/lib/notify.sh` → `plugin/lib/notify.sh` unchanged except the
      header. cc `scripts/lib/bash-env.sh` sources the plugin path. Verify: new cc session,
      `type say_notify` reports a function with zero source lines in the calling command.
- [ ] 1.3 Move cc `output-styles/tts-summary.md` → `plugin/output-styles/` and inject it
      through a fail-soft `SessionStart` hook as additional context. Remove cc's stale
      `outputStyle` setting. Verify: a new plugin-enabled session receives the guidance.

## 2. Mute support in the pipe

- [ ] 2.1 `bin/notify.sh`: before synthesis, if `$HERALD_STATE_DIR/mute` exists and its
      content (epoch expiry) is in the future, append a `muted` history record and exit 0.
      Verify: shell test — mute set → no ssh spawned, `muted` record; expired mute file →
      normal path and the file is cleaned up. Add `muted` to the canonical closed outcome
      set in code, tests, Herald's ground rules, and the notify-pipeline spec.

## 3. The `/notify` command

- [ ] 3.1 Author `plugin/commands/notify.md` with subcommands status / history / mute /
      unmute / test / voices / default-send, each an explicit shell snippet against
      `$HERALD`. Frontmatter per cc `commands/references/frontmatter-schema.md`
      (`execution: blocking`). The `voices` subcommand MUST consume
      `herald notify voices --json` and MUST NOT parse `voices.json` directly. Verify:
      `/notify status`, `/notify history 5`, and `/notify voices` in a live cc session.
- [ ] 3.2 `/notify test` runs the pipe with `--wait` and prints the resulting history
      line. Verify: audible + record shown.

## 4. cc spec + caller cleanup

- [ ] 4.1 Rewrite cc `openspec/specs/notify-command/spec.md` against the herald backend:
      same requirement structure, Nexus scenarios replaced by herald equivalents; keep
      § Blocker Attention Notify verbatim (emitter contract unchanged). Verify: spec's own
      grep scenarios pass.
- [ ] 4.2 Collapse `orch_tts_notify` (cc
      `skills/orchestrator-patterns/scripts/orchestrator-helpers.sh:339-344`) to a bare
      `say_notify "$message"` — no re-source, no backgrounding. Verify:
      `grep -n "source.*notify" orchestrator-helpers.sh` empty.
- [ ] 4.3 Update cc `skills/deploy-and-env/references/notifications.md` to the plugin
      architecture (v5) and delete the moved cc files. Verify: cc `validate-cc` passes.

## 5. Evidence

- [ ] 5.1 Session transcript snippet: `/notify mute 1h` → silent `say_notify` → `muted`
      record → `/notify unmute` → audible test.
