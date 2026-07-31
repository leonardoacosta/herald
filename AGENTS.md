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
  (delivered / synth_failed / transport_timeout / transport_failed) — stderr on a
  fire-and-forget hook is not observability.
- **Single speech path.** Exactly one function (`say_notify`) and one pipe. No parallel
  speech implementations, no compatibility aliases for retired transports.

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
