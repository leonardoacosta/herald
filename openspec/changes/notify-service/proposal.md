---
order: 0801a
---

# Proposal: Herald becomes a line of service

## Change ID

`notify-service`

## Context

- touches: `cmd/herald/main.go`, `pkg/notify/cli.go`, `bin/notify.sh`, `bin/lib.sh`, `plugin/commands/notify.md`, `AGENTS.md`, `README.md`
- base-commit: herald@5b152d1

New files this proposal creates — deliberately kept OUT of `- touches:` above, which exists to
drive the wave conflict matrix: a file nothing else can be editing yet cannot collide, and
`wave-plan-build` mangles a `(new)`-suffixed token into a bogus path (`pkg/notify/service.go (new`)
that then pollutes the matrix. Named here instead: `pkg/notify/service.go`, `pkg/notify/mute.go`,
`bin/service-sync.sh`, `tests/notify-service.test.sh`.

## Why

Leo, 2026-08-01, correcting a premise: *"I was under the impression that Herald would be a
line of service, not an ephemeral send."* The code disagreed with the model, and the code was
wrong.

Herald today has no service. There is no `ListenAndServe`, no `net.Listen`, no socket anywhere
in `pkg/` or `cmd/`; `cmd/herald/main.go` is a pure argv dispatcher that parses, runs, and
exits. Every notification re-execs a shell script and a Go binary, and callers coordinate
through **files** — `voices.json`, `notify.ndjson`, `mute`, `/tmp/herald-spool`. Everything
*around* herald is a service (Kokoro is a containerized HTTP service; the playback daemon added
by `warm-playback` is resident under launchd). Herald is the only ephemeral link in its own
chain.

That has a concrete cost, and it is already visible. The control surface is split three ways,
and only two layers can be reached by a non-Claude caller:

| Layer | Lives in | Reachable by pi |
| --- | --- | --- |
| synth / voices / catalog / set / reset / audition | `herald` binary | yes |
| delivery, mute **enforcement** | `bin/notify.sh` | yes |
| mute / unmute / status / history | `plugin/commands/notify.md` — a Claude command file | **no** |

The mute file proves the hazard: its **writer** (duration parsing, epoch arithmetic, atomic
`mktemp`+`mv`) lives in Claude-only markdown, its **reader** lives in `bin/notify.sh:105-117`,
and the format itself is owned by neither — `pkg/notify` knows the `muted` history outcome and
nothing about the file. No test covers the writer. A second caller must reimplement epoch
semantics against an undocumented format, and any drift is silent.

So "augment with other callers" today means every new caller reimplements herald's file
formats. A service makes them clients instead.

## What Changes

**Herald gains a resident service that owns the notification path end to end**, with the
existing CLI/pipe kept as its fallback transport.

- **`herald notify serve`** — an HTTP listener bound to loopback **and** the Tailscale
  address, never `0.0.0.0`, mirroring the posture `compose/kokoro.yml` already documents for
  Kokoro. The bind address is the access control; there is no credential (see `## Decisions`).
- **Send**: `POST /notify {text, project}` becomes the primary path, and it **accepts rather
  than completes**. The service validates, checks mute, enqueues, and returns `202` in
  milliseconds; synthesis and delivery run asynchronously, and the history record remains the
  observability surface exactly as `AGENTS.md` already specifies.

  This is not a style preference — a synchronous endpoint is unshippable here. Synthesis is
  2.5-8.5s measured, and `say_notify`'s caller bound is 15s. A slow or cold synthesis times the
  client out AFTER the service has already delivered, the client falls through to the local
  path, and the notification is spoken twice. Returning early collapses the client's exposure
  window to a connection attempt, so the fallback fires only on genuine unreachability — which
  is the only condition under which it is safe to fire at all.

- **`--wait` stays local.** It blocks through playback for evidence capture (`/notify test`),
  which an accept-and-queue endpoint cannot express. A `--wait` call bypasses the service and
  runs the local path directly. This is a deliberate carve-out, not an oversight: the one caller
  that wants to block is the one caller that does not want a queue.
- **Control**: `POST /mute`, `POST /unmute`, `GET /status`, `GET /history?n=` — the surface
  that exists only as markdown today.
- **Logic consolidation, first**: mute (duration parsing, expiry, atomic replace), status, and
  history rendering move OUT of `plugin/commands/notify.md` and INTO `pkg/notify`, where they
  get an owner and a test. The HTTP handlers and the CLI subcommands both become thin adapters
  over that one implementation. This phase is required for any transport and is valuable even
  if the listener were never built.
- **Callers become clients**: `bin/notify.sh` posts to the service and falls back to today's
  local logic when it is unreachable. `plugin/commands/notify.md` branches become thin calls.
  `say_notify`'s contract is unchanged from the operator's point of view.

**Fail-soft is preserved by construction, not by care.** `warm-playback` already shipped this
exact pattern: the resident player does the fast thing while it holds the lock, and when it
dies the lock goes stale and delivery falls back to `afplay` automatically. Same shape here —
service when up, current path when not. A notification MUST NOT depend on the daemon being
healthy.

## Amendment 2026-08-01 — one config instance, not two resolutions

Leo, after the 15 tasks landed: *"why do we even need to set these environment variables this
way — the service should receive them at deployment time and the caller should be invoked by the
same env file. Separating them only causes this type of tension."*

The tension was found by a regression: `tests/notify-brief.test.sh` isolates itself with
`HERALD_STATE_DIR` and a dead `HERALD_KOKORO_BASE_URL`, and once `bin/notify.sh` became a service
client (1.7) those overrides were silently ignored — the request went to the live service, which
used its own state dir and its own Kokoro, and spoke aloud. The test is not flaky; it is
correctly detecting that caller and service stopped describing the same pipeline.

The root cause is not the client change. It is that **the two halves resolve configuration
independently and are bound to nothing**:

- `bin/service-sync.sh` resolves every value ONCE at install time (`herald_config`) and freezes
  the results into literal `Environment=` lines in the unit.
- `bin/notify.sh` resolves the same values through the same `herald_config` on EVERY invocation.
- There is no `~/.config/herald/config` on this host, so the two agree today only because both
  fall through to identical defaults. Nothing enforces it.

The failure this shape guarantees, independent of the test: write a config file changing the
Kokoro URL and `bin/notify.sh` honors it on the next call while the service keeps serving the
frozen value until someone re-runs `service-sync.sh` — a silent split between the two halves of
one pipeline, with no error surfaced anywhere. A snapshot taken at install time is not
configuration; it is a copy that goes stale.

**What changes**: one env file is the single instance both halves read — systemd via
`EnvironmentFile=`, the shell via `source`. Same file, same values, no re-resolution. A plain
`KEY=value` file is valid input to both, which is what makes the convergence possible at all.

Two defects surfaced while investigating, both in scope here:

- `bin/lib.sh` defaults `HERALD_STATE_DIR` (line 5) BEFORE sourcing the config file (line 12), so
  a config file carrying `HERALD_STATE_DIR=` would clobber a caller's explicitly-inherited value.
  The file must lose to a real environment variable, not win.
- The config file's variables are named `NOTIFY_*` while the environment's are `HERALD_*`
  (`herald_config`'s two-vocabulary precedence). A file consumed by systemd must carry the names
  the service actually reads, so the shared file uses `HERALD_*` and `NOTIFY_*` becomes the
  legacy layer.

**Divergence becomes explicit rather than silent.** With one shared file defining the deployed
pipeline, a caller whose resolved config differs from that file is by definition describing a
DIFFERENT pipeline than the running service — so `bin/notify.sh` bypasses the service and runs
locally, the same carve-out `--wait` already uses. That is what makes `notify-brief.test.sh` pass
again without weakening it: the test genuinely is a different pipeline, and now says so.

## Non-goals / out of scope

- **No mid-flight control** (stop, skip, pause, volume). `serial-playback` and `warm-playback`
  both declare "No priority lane or interruption"; `deep-briefings` declares "No
  streaming/interruptible playback". Reversing that is a separate proposal with its own
  evidence — this one only builds the seam it would land on.
- **No per-call voice/speed override.** Real gap, follows naturally once the service owns the
  request, but not this change.
- No authentication (see `## Decisions`). No TLS — the tailnet is the transport.
- No change to Kokoro, to the playback host, or to the spool/drainer contract.
- Not a general-purpose service: it notifies and reports on notifications, nothing else.

## Exemplars

- **Bind posture to copy verbatim**: `compose/kokoro.yml` ports block — loopback plus the
  Tailscale address injected at deploy time, never baked in, never `0.0.0.0`.
- **Service-with-fallback pattern**: `bin/herald-player.sh` + `bin/notify.sh`'s spool drainer —
  the resident process wins while alive, the old path resumes automatically when it dies.
- **Host provisioning shape**: `bin/kokoro-sync.sh` (execution host) and `bin/player-sync.sh`
  (playback host) — `bin/service-sync.sh` is the third in that family.
- **Stable JSON output**: `herald notify voices --json` — the one control branch already
  delegated correctly, and the model for every new endpoint.

## Preconditions

- `test -x bin/herald` → the CLI binary exists
- `test -x bin/notify.sh` → the pipe is executable
- `test -f go.mod` → Go module root resolves
- `command -v tailscale` → the bind-address source is installed
- `tailscale ip -4` → a tailnet address resolves for the listener to bind
- `curl -sf -m 5 -o /dev/null http://127.0.0.1:8880/health` → Kokoro is reachable for synthesis
- premise: no listener exists today — verified: `rg "ListenAndServe|net.Listen|http.Server"
  pkg/ cmd/` returns nothing @ herald@5b152d1
- premise: mute's writer lives in `plugin/commands/notify.md` and `pkg/notify` knows nothing of
  the file — verified: grep of the mute branch vs `rg -in mute pkg/` @ herald@5b152d1
- premise: `herald notify synth` has no per-call voice/speed flags — verified:
  `./bin/herald notify synth --help` @ herald@5b152d1

## Done Means

- A tailnet caller (pi) sends a notification with one HTTP request, knowing no file formats and
  running no shell scripts.
- The operator can mute, unmute, and read status and history through that same API.
- A notification still speaks when the service is down — the existing CLI/pipe path takes over
  without the caller doing anything differently.
- `/notify` and `say_notify` behave identically from the operator's point of view.
- Mute means the same thing whichever path handled it, because one implementation decides it.

## Testing

- **`pkg/notify` mute/status/history** — Go unit tests against the consolidated implementation:
  duration parsing (`s`/`m`/`h`/`d`, rejection of malformed input), expiry boundary, atomic
  replace, and expired-file cleanup. This is the coverage the markdown writer never had.
  Tasks 1.1, 2.1.
- **Service endpoints** — Go tests over `httptest`: `POST /notify` appends exactly one history
  record; `POST /mute` then `POST /notify` records `muted` and contacts no playback host;
  `GET /status`/`GET /history` emit stable JSON. Tasks 1.4, 1.5, 2.1.
- **Fallback** — `tests/notify-service.test.sh`: with the service down, `bin/notify.sh` still
  delivers and still records; with it up, the same call routes through the service. Asserts
  both paths never double-send. Task 2.2.
- **No double-send on slow synthesis** — the specific race that shaped the design: with the
  service reachable but synthesis artificially slowed past the caller's bound, exactly one
  history record appears. This fails against a synchronous endpoint, which is the point.
  Task 2.2.
- **Bind posture** — assert the listener is reachable on loopback and the tailnet address and
  NOT on a third interface. Task 2.3.
- **Cross-host** — a real `curl` from the Mac over the tailnet produces audible speech and one
  history record. Task 2.4.

## Decisions

- Transport — chosen: HTTP bound to loopback + the Tailscale address, mirroring
  `compose/kokoro.yml`; rejected: unix-domain socket (callers are cross-host, confirmed pi does
  not run on the herald box), rejected: staying an ephemeral CLI; decided-by: leo
- Request semantics — chosen: `POST /notify` accepts and queues, returning `202` immediately
  with synthesis and delivery async; rejected: a synchronous endpoint (2.5-8.5s synthesis
  against a 15s caller bound means a timeout after successful delivery, and the fallback then
  double-sends), rejected: synchronous plus client-supplied idempotency keys (dedup state to
  own, for a response nobody needs); decided-by: leo
- Send-path implementation — chosen: port the delivery leg into `pkg/notify` so the service
  owns synthesis and transport natively; rejected: the service exec'ing `bin/notify.sh` per
  request; decided-by: leo. **Recorded tradeoff**: the rejected option was smaller and reused
  delivery code that four documented constraints were paid for in incidents (the `timeout(1)`
  wrapper, the ban on `ssh -n`, rename-after-complete into the spool, and the trap window). The
  port MUST carry all four across, with the shell version's comment block as the spec. Scope is
  narrower than it first appears: voice resolution, synthesis, and history are already Go — only
  the ssh delivery and spool enqueue are shell-only.
- `--wait` — chosen: bypasses the service and runs the local path; rejected: a `?wait=true`
  synchronous mode (reintroduces exactly the timeout window `202` exists to close);
  decided-by: default
- Service scope — chosen: send AND control, so `POST /notify` is the primary path and pi needs
  no file-format knowledge; rejected: control-only (leaves pi shelling out for the thing it
  actually wants), rejected: send-only (leaves the ownerless mute format in place);
  decided-by: leo
- Authentication — chosen: none; the bind address is the access control, matching Kokoro's
  documented posture in this repo; rejected: shared-token header; decided-by: leo
- Fail-soft posture — chosen: service when up, existing CLI/pipe path when not, mirroring
  `warm-playback`'s resident-player/`afplay`-drainer fallback; rejected: any hard dependency on
  the daemon being healthy; decided-by: default (AGENTS.md fail-soft is non-negotiable)
- Phasing — chosen: consolidate control logic into `pkg/notify` first, HTTP adapter second;
  rejected: building handlers against logic still scattered across markdown, shell, and Go;
  decided-by: default

## STOP conditions

- Any design where the service being down can silence a notification rather than fall through
  to the local path — report it; that inverts herald's one non-negotiable contract.
- Two paths both delivering the same notification (service AND fallback) — a double-send is
  worse than a missed optimisation; report rather than paper over with timing.
- The listener binding anything broader than loopback + the tailnet address.
- Mute semantics diverging between the API path and the fallback path — the whole point of the
  consolidation is that one implementation decides it.
