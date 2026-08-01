# AGENTS.md — herald

Single-responsibility notification service. If a change is not about getting an operator's
attention (speech, mobile push, history, control surface), it does not belong here.

## Ground rules

- **Fail-soft is the contract.** Every public entry point (`say_notify`, `bin/notify.sh`,
  hook wiring) ALWAYS exits 0 and is bounded by a timeout. Callers treat notifications as
  decoration; a notification failure must never break a hook, a session exit, or a turn.
  This contract predates herald (herdr-shepherd's notify pipe, cc's `notify-transport` spec)
  and is non-negotiable.
- **No hardcoded host addresses.** Service addresses (Kokoro base URL, playback host) are
  deployment configuration resolved from env/config with documented defaults — never baked
  into Go or committed compose output.
- **Never reproduce secret values** in code, docs, or history records.
- **History is the debugging surface.** Every notify attempt appends one record
  (delivered / muted / synth_failed / transport_timeout / transport_failed) — stderr on a
  fire-and-forget hook is not observability.
- **Single speech path.** One pipe, one implementation. `say_brief` exists alongside
  `say_notify` as a named entry point for long-form digests, but it is a bound — it delegates
  to `say_notify` in the same file rather than reimplementing anything. A third name is only
  legitimate on those same terms. No parallel speech implementations, no compatibility aliases
  for retired transports.
- **Briefings are explicit-only.** `say_brief` fires because the operator asked for a
  briefing. Never from a hook, an agent completion, a session-exit event, or a schedule.
- **One voice at a time.** The playback host plays at most one clip at any moment.
  Concurrent notifications are spooled and drained in arrival order by a single
  mkdir-elected drainer — never mixed, never dropped. Concurrency is the normal case here
  (two agents notifying at once), so anything that launches a player directly is a defect.
  **Silence is the worse failure**: every ambiguous lock state resolves toward playing, and
  a drainer that dies leaves a lock the next caller breaks rather than one that mutes the
  host.

## Layout

| Path | Role |
|---|---|
| `bin/` | Shell entry points (notify pipe, kokoro-sync) |
| `pkg/notify/` (Go module) | Voice resolution, Kokoro client, history store |
| `compose/` | Kokoro compose module (source of truth; host copy is generated) |
| `plugin/` | CC plugin (commands, lib, output-style) imported by harnesses |
| `docs/` | Attention-channel doctrine, per-harness wiring |
| `openspec/` | Specs and change proposals |

## Workflow

OpenSpec-driven: propose in `openspec/changes/<slug>/` (proposal.md + tasks.md + spec
deltas), get approval, implement via tasks.md, archive on completion. Same conventions as
`~/dev/cc` (see its `openspec/AGENTS.md` for the canonical process).
