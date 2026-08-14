# Tasks — moshi-hook-parity

## 1. Inventory (no edits)

- [ ] 1.1 Enumerate moshi-hook's modes/vocabulary (`moshi-hook --help`,
      getmoshi.app/docs/hooks) and each harness's supported hook types (claude hook
      events; codex hooks.json schema; pi extension events). Verify: written matrix,
      every cell cited.
- [ ] 1.2 Verify pi's post-bridge state: does an `ask_user` block reach Moshi as
      PermissionRequest today? Evidence: trigger one and check the Moshi inbox.

## 2. Close gaps

- [ ] 2.1 codex: add SessionEnd (and ask/plan attention if the platform exposes it) to
      `hooks.json`, matching the existing entry shape. Verify: JSON parses; event lands
      in Moshi inbox.
- [ ] 2.2 claude: reconcile the 9 wirings against the matrix — remove dead ones, add
      missing ones. Verify: each remaining entry maps to a matrix row.
- [ ] 2.3 pi: any addition goes in a NEW sibling extension (never edit
      `agent/extensions/*`), following the bridge change's pattern.

## 3. Doctrine

- [ ] 3.1 Write `docs/attention-channels.md`: channel diagram (speech / Moshi / history),
      single-emitter rule for blocking asks, the parity matrix, per-harness debugging
      checklist. Verify: every claim carries a `file:line` or doc citation.

## 4. Evidence

- [ ] 4.1 One event per harness photographed/recorded reaching the phone; attached to
      the PR.
