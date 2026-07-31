# CLAUDE.md

Read `AGENTS.md` — it is the canonical agent guidance for this repo. Highlights:

- Fail-soft contract: every notification path exits 0, bounded by a timeout.
- Single speech path: `say_notify` → `bin/notify.sh` → `herald notify` → Kokoro → playback.
- OpenSpec workflow: changes live in `openspec/changes/<slug>/`; specs in `openspec/specs/`.
- Scope discipline: attention channels only. Anything else belongs in another repo.
