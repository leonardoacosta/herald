# AGENTS.md — herald

Single-responsibility notification service. If a change is not about getting an operator's
attention (speech, mobile push, history, control surface), it does not belong here.

## Ground rules

- **Fail-soft is the contract.** Every public entry point (`say_notify`, `bin/notify.sh`,
  hook wiring) ALWAYS exits 0 and is bounded by a timeout. Callers treat notifications as
  decoration; a notification failure must never break a hook, a session exit, or a turn.
  This contract predates herald (herdr-shepherd's notify pipe, cc's `notify-transport` spec)
  and is non-negotiable.
- **Fallback guarantee: the service being down never silences a notification.**
  `bin/notify.sh` posts to `herald notify serve`'s `POST /notify` first and falls through to
  the local CLI/pipe path ONLY when the request never reached the service — DNS failure,
  connection refused, or the connect phase itself timing out. Never on a slow response, an
  HTTP error, or a `503` queue-full: those mean a TCP connection was made, and the service may
  already have written the history record for that attempt, so falling back would speak it
  twice. `--wait` bypasses the service outright and always runs the local path, for evidence
  capture.
- **No hardcoded host addresses.** Service addresses (Kokoro base URL, playback host) are
  deployment configuration resolved from env/config with documented defaults — never baked
  into Go or committed compose output.
- **The notify service binds loopback plus the tailnet address, never `0.0.0.0`** — the same
  posture `compose/kokoro.yml` documents for Kokoro, and for the same reason: there is no
  credential, so the bind address IS the access control. `herald notify serve` resolves its
  own tailnet address (`tailscale ip -4`) at process start rather than baking one in;
  `HERALD_NOTIFY_PORT` (default `8881`) and `HERALD_NOTIFY_BIND_TAILSCALE_IP` are the
  overrides, read fresh every start.
- **Never reproduce secret values** in code, docs, or history records.
- **History is the debugging surface.** Every notify attempt appends one record
  (delivered / muted / synth_failed / transport_timeout / transport_failed) — stderr on a
  fire-and-forget hook is not observability.
- **`POST /notify` accepts, it does not complete.** It validates, checks mute, and enqueues
  before responding `202` — in milliseconds — and synthesis and delivery run afterward on a
  single async worker; the history record above is the only place that later outcome shows
  up. This is not a style choice: synthesis measures 2.5-8.5s against `say_notify`'s 15s
  caller bound, so a synchronous endpoint can time the client out AFTER delivery already
  happened, and the fallback then speaks it twice.
- **Single speech path.** One pipe, one implementation. `say_brief` exists alongside
  `say_notify` as a named entry point for long-form digests, but it is a bound — it delegates
  to `say_notify` in the same file rather than reimplementing anything. A third name is only
  legitimate on those same terms. No parallel speech implementations, no compatibility aliases
  for retired transports.
- **Briefings are explicit-only.** `say_brief` fires because the operator asked for a
  briefing. Never from a hook, an agent completion, a session-exit event, or a schedule.
- **The playback host stays warm.** A resident player (`bin/herald-player.sh`, installed by
  `bin/player-sync.sh` under a launchd agent) holds an open output stream and plays silence
  between clips, because the audio device powers down when idle and waking it costs ~420ms —
  measured 506-559ms per clip cold against 82-96ms warm. It releases the device after an idle
  window and reacquires on the next clip. **Delivery never depends on it**: it holds the spool
  lock for its lifetime so the fallback drainer cannot play alongside it, and if it dies the
  lock goes stale and the next notification plays the old way. A latency optimisation that can
  silence a notification is not one.
- **One voice at a time.** The playback host plays at most one clip at any moment.
  Concurrent notifications are spooled and drained in arrival order by a single
  mkdir-elected drainer — never mixed, never dropped. Concurrency is the normal case here
  (two agents notifying at once), so anything that launches a player directly is a defect.
  **Silence is the worse failure**: every ambiguous lock state resolves toward playing, and
  a drainer that dies leaves a lock the next caller breaks rather than one that mutes the
  host.
- **Service lifecycle is `bin/service-sync.sh`.** Installs/refreshes the systemd **user**
  unit `herald-notify.service`, enables it, starts it, and polls `/health`; `--status`
  reports unit and health state; `--diff` previews unit changes with nothing applied;
  `--remove` stops, disables, and drops the unit, leaving the CLI/pipe fallback intact. A
  user unit, not a system unit — the daemon needs Leo's `$HERALD_STATE_DIR` and SSH identity
  for delivery, which a root-run system unit would not have. **Rebuilding `bin/herald` does
  not reach the running service by itself**: `ExecStart` points at that file on disk, and
  systemd has no way to notice it changed underneath the running process. After
  `go build -o bin/herald ./cmd/herald`, re-run `bin/service-sync.sh` — it compares the
  running build's version against the on-disk binary and restarts on mismatch — or restart
  the unit directly.

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
