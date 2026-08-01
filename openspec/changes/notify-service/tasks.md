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
      existing `voices --json`. Verify: `herald notify status --json` and
      `herald notify history --json -n 5` emit parseable JSON with the pipe down.
- [ ] 1.3 Add `herald notify serve` — HTTP listener bound to loopback AND the Tailscale
      address only, address injected at start like `compose/kokoro.yml` does for Kokoro, never
      baked in and never `0.0.0.0`. Verify: listener answers on both addresses; binding is
      refused/absent on any other interface.
- [ ] 1.4 `POST /notify {text, project}`: resolve voice, check mute, synthesize, deliver,
      append exactly one history record — the same sequence `bin/notify.sh` runs today.
      Verify: httptest asserts one record per call and `muted` when mute is active, with no
      playback host contacted in that case.
- [ ] 1.5 Control endpoints `POST /mute`, `POST /unmute`, `GET /status`, `GET /history?n=`,
      all delegating to 1.1/1.2 rather than reimplementing. Verify: httptest per endpoint;
      mute set via HTTP is observed by the CLI path and vice versa.
- [ ] 1.6 `bin/notify.sh` becomes a client: post to the service, and on any failure to reach
      it fall through to today's local logic unchanged. Exactly one path may deliver.
      Verify: shell test asserts delivery with the service up, delivery with it down, and one
      history record in both cases — never two.
  - depends on: 1.4
- [ ] 1.7 Rewrite `plugin/commands/notify.md`'s `status`, `history`, `mute`, `unmute` branches
      as thin callers of the binary, matching how `voices` already delegates. Verify: no
      duration arithmetic or epoch math remains in the markdown (`grep` for `multiplier` and
      `date +%s` is empty).
- [ ] 1.8 `bin/service-sync.sh` — install and supervise the service on the execution host,
      third in the family with `kokoro-sync.sh` and `player-sync.sh`: idempotent re-run,
      `--status`, `--remove`. Verify: fresh install starts it, a second run is a no-op,
      `--remove` leaves the fallback path working.

## E2E Batch

- [ ] 2.1 Go tests for `pkg/notify` mute/status/history and the service handlers (httptest).
      Verify: `go test ./...` passes.
- [ ] 2.2 `tests/notify-service.test.sh` — fallback contract: service up routes through HTTP,
      service down routes locally, and a burst across the transition never double-sends.
      Verify: test passes, and fails if the fallback is removed.
- [ ] 2.3 Bind-posture assertion: reachable on loopback and the tailnet address, absent
      elsewhere. Verify: test output showing both reachable and a third interface refused.
- [ ] 2.4 Cross-host proof: `curl` from the Mac over the tailnet produces audible speech and
      one history record. Verify: command + resulting history line pasted.
- [ ] 2.5 Update `AGENTS.md` (service lifecycle, bind posture, fallback guarantee beside the
      existing fail-soft and one-voice-at-a-time rules) and `README.md`'s architecture
      diagram. Verify: rules present and naming the fallback guarantee.

## User Gate

- [ ] [user:post] 3.1 DECISION: make the service the default transport for `say_notify`, or keep the local pipe primary until it has run a while? Answerable only after 2.4 proves the cross-host path in practice. searched: `AGENTS.md` ground rules, `openspec/specs/notify-pipeline/spec.md`, and the archived `warm-playback` proposal; no documented pattern covers when a herald fallback graduates to primary — `warm-playback` set the fallback precedent but never had to pick a default transport.
  - Option 1: Service primary immediately — every caller gets one path, and the fallback is
    genuinely exceptional. Fastest convergence; a service bug reaches every notification.
  - Option 2: Local pipe primary, service opt-in via env for pi only — lowest risk to Leo's
    own notifications while pi proves the API. Two live paths for longer.
  - Option 3: Service primary after N days with zero fallback activations recorded in the
    history — evidence-gated cutover. Needs a fallback-activation counter that does not exist
    yet.
