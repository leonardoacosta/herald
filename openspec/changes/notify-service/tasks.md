---
stack: infra
---

# Tasks — notify-service

## API Batch

- [ ] 1.1 Move mute into `pkg/notify` as the single owner of the file's format: duration
      parsing (`s`/`m`/`h`/`d`, reject non-positive and malformed), epoch expiry, atomic
      temp+rename write, and expired-file cleanup. Verify: Go unit tests cover parse
      rejection, the expiry boundary, and that an expired file is removed on read.
- [ ] 1.2 Move status and history readout into `pkg/notify` with stable JSON, alongside the
      existing `voices --json`. Status carries a build version so a client can detect skew
      against a stale running service. Verify: `herald notify status --json` and
      `herald notify history --json -n 5` emit parseable JSON with the pipe down.
- [ ] 1.3 Port the delivery leg into `pkg/notify`: spool enqueue (write to a dot-prefixed name,
      rename in only once complete) and ssh transport. ALL FOUR documented constraints carry
      across from `bin/notify.sh`'s comment block, which is the spec for this task — the
      `timeout(1)` wrapper bounding wall clock, NO `ssh -n` (it discards the piped audio
      silently), rename-after-complete so no drainer reads a partial clip, and the trap window
      covering mktemp-to-bytes-landed. Verify: Go tests assert each constraint; a delivery to an
      unreachable host records `transport_timeout` within the bound, not a hang.
- [ ] 1.4 Add `herald notify serve` — HTTP listener bound to loopback AND the Tailscale
      address only, address resolved at start like `compose/kokoro.yml` does for Kokoro, never
      baked in and never `0.0.0.0`. Verify: listener answers on both addresses; binding is
      absent on any other interface.
  - depends on: 1.1
- [ ] 1.5 `POST /notify {text, project}` — validate, check mute, enqueue, return `202`
      immediately. Synthesis and delivery run on an async worker using 1.3. Exactly one history
      record per accepted request, whatever the outcome. Verify: httptest asserts the response
      returns in milliseconds while synthesis is stubbed slow, and that one record lands per
      call including the `muted` case with no playback host contacted.
  - depends on: 1.3, 1.4
- [ ] 1.6 Control endpoints `POST /mute`, `POST /unmute`, `GET /status`, `GET /history?n=`,
      all delegating to 1.1/1.2 rather than reimplementing. Verify: httptest per endpoint;
      mute set via HTTP is observed by the CLI path and vice versa.
  - depends on: 1.4
- [ ] 1.7 `bin/notify.sh` becomes a client: post to the service and fall through to today's
      local logic ONLY on failure to reach it — never on a slow or error response, which may
      mean the service already delivered. `--wait` bypasses the service entirely and runs the
      local path. Verify: shell test asserts delivery with the service up, with it down, and
      exactly one history record in both cases.
  - depends on: 1.5
- [ ] 1.8 Rewrite `plugin/commands/notify.md`'s `status`, `history`, `mute`, `unmute` branches
      as thin callers of the binary, matching how `voices` already delegates. Verify: no
      duration arithmetic or epoch math remains in the markdown (`grep` for `multiplier` and
      `date +%s` is empty).
  - depends on: 1.2
- [ ] 1.9 `bin/service-sync.sh` — install and supervise the service on the execution host under
      **systemd** (the homelab box's supervisor, as `player-sync.sh` uses launchd and
      `kokoro-sync.sh` uses docker compose): unit file, restart on failure, start on boot,
      idempotent re-run, `--status`, `--remove`. Verify: fresh install starts it, a second run
      is a no-op, `--remove` leaves the fallback path working.
  - depends on: 1.4

## E2E Batch

- [ ] 2.1 Go tests for `pkg/notify` mute/status/history/delivery and the service handlers
      (httptest). Verify: `go test ./...` passes.
- [ ] 2.2 `tests/notify-service.test.sh` — the fallback contract AND the race it exists to
      close: service up routes through HTTP; service down routes locally; and with the service
      reachable but synthesis artificially slowed past the caller's bound, exactly ONE history
      record appears. Verify: test passes, and the slow-synthesis case fails if the endpoint is
      made synchronous.
- [ ] 2.3 Bind-posture assertion: reachable on loopback and the tailnet address, absent
      elsewhere. Verify: test output showing both reachable and a third interface refused.
- [ ] 2.4 Cross-host proof: `curl` from the Mac over the tailnet produces audible speech and
      one history record. Verify: command + resulting history line pasted.
- [ ] 2.5 Update `AGENTS.md` (service lifecycle, bind posture, accept-and-queue semantics, and
      the fallback guarantee beside the existing fail-soft and one-voice-at-a-time rules) and
      `README.md`'s architecture diagram. Verify: rules present and naming the fallback
      guarantee.

## User Gate

- [ ] [user:post] 3.1 DECISION: make the service the default transport for `say_notify`, or keep the local pipe primary until it has run a while? Answerable only after 2.4 proves the cross-host path in practice. searched: `AGENTS.md` ground rules, `openspec/specs/notify-pipeline/spec.md`, and the archived `warm-playback` proposal; no documented pattern covers when a herald fallback graduates to primary — `warm-playback` set the fallback precedent but never had to pick a default transport.
  - Option 1: Service primary immediately — every caller gets one path, and the fallback is
    genuinely exceptional. Fastest convergence; a service bug reaches every notification.
  - Option 2: Local pipe primary, service opt-in via env for pi only — lowest risk to Leo's
    own notifications while pi proves the API. Two live paths for longer.
  - Option 3: Service primary after N days with zero fallback activations recorded in the
    history — evidence-gated cutover. Needs a fallback-activation counter that does not exist
    yet.
