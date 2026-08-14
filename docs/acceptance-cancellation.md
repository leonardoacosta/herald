# Cancellation and playback acceptance protocol

`tests/acceptance-cancellation.sh` is Herald's rerunnable proof that the **currently
deployed** pipeline — the running service, the on-disk binary, the shared config file,
the resident player on the playback host, and the spool protocol — still cooperates for
scoped cancellation and serialized playback.

It exists because the original acceptance evidence was point-in-time. A rebuild of
`bin/herald` does not reach the running service on its own (AGENTS.md), so "it worked
once" is not a claim that survives the next `go build`. This harness re-earns the claim
on demand and writes durable evidence.

## Explicit-only

An operator runs it. It is never wired into a hook, a schedule, a session-exit event,
an agent completion, or CI without opt-in — the same posture as briefings. Its own test
(`tests/acceptance-cancellation.test.sh`) enforces this by failing if anything in the
repo outside docs references it.

## Running it

```bash
tests/acceptance-cancellation.sh                 # gate 0 + no-audio contract checks
tests/acceptance-cancellation.sh --live          # full matrix; PLAYS REAL AUDIO
tests/acceptance-cancellation.sh --live --out /tmp/run1.json
```

`--live` is an **authorization flag, not a verbosity flag**. It means someone has
confirmed it is acceptable for the house to make noise right now. Without it the run
performs gate 0 and only the sub-checks that provably make no sound (malformed `POST
/notify`, malformed and unknown-ID `POST /notify/stop`), and reports `partial`.

Requires `jq` and `curl`. A `--live` run is bounded under three minutes; every network
call carries its own timeout.

## Gate 0: version and deployment alignment

The run aborts cleanly — non-zero exit, **no audio**, report still written — unless all
hold:

| Check | Failure means |
|---|---|
| `herald-notify.service` is active and `/health` answers | Service not deployed; run `bin/service-sync.sh` |
| Running version == on-disk `bin/herald` version | Stale service; re-run `bin/service-sync.sh` |
| Resolved state dir == shared config file's declared value | `bin/notify.sh` would bypass the service; test traffic would be rerouted |
| Resolved Kokoro URL == shared config file's declared value | Wrong synthesis engine would answer |

The harness **never** restarts, reloads, or reconfigures the service. A stale deployment
is reported with its remediation and the run stops there.

Playback-host reachability is checked but is **not** fatal: if the host is unreachable,
rows needing boundary evidence become `blocked` and the verdict caps at `partial`.

## The playback host is observed, never mutated

Every call to the playback host is a read (`ls`, `cat`, `tail`) over the SSH identity
delivery already uses. The harness does not install, restart, or kill
`bin/herald-player.sh`, its launchd agent, or any player process — that lifecycle stays
owned by `bin/player-sync.sh`.

Boundary evidence collected before and after each run: spool directory listing, lock
holder pid, `.player.pid`, the in-flight request ID, and the player log tail.

**Delivery mode is recorded, not forced.** The harness derives which mode served the
run (`resident-player` when the lock holder is the resident player's pid,
`fallback-drainer` when someone else holds it, `idle` when nobody does). Forcing the
other mode would mean killing the resident player, which is a mutation this harness
refuses. Whichever mode was not live is `not-exercised`, never `pass`.

## Test matrix

| # | Case | Expected |
|---|------|----------|
| 1 | Plain notify via service | `202` + request_id, one `delivered` row, served once |
| 2 | Notify `--wait` (local path by design) | exits 0 in bound, one row, no double-speak |
| 3 | Queued cancellation | `canceled` row, no delivery evidence |
| 4 | Active-playback cancellation | clip interrupted, one `canceled` row |
| 5 | Unrelated survival | B still delivered while A was canceled |
| 6 | Stop idempotency / unknown ID | `stopped:false`, zero new history rows |
| 7 | Serialization under concurrency | both delivered, order preserved, never mixed |
| 8 | Mute respected | `muted` row, no playback, mute restored |
| 9 | HTTP contract spot-checks | documented accepted/malformed/unknown shapes |

Rows 4 and 5 run as one scenario: "cancelling A did not silence or reorder B" is only
evidenced from a single timeline.

Row 2 correlates by the run nonce embedded in the utterance rather than by request ID,
because `--wait` bypasses the service by design and therefore has no request ID.

## History correlation

Every accepted request must map to **exactly one** terminal history row. The harness
polls until a row appears, then waits an extra second and re-reads — a *delayed*
duplicate write fails the row instead of racing past the check. Outcomes must come from
the closed set (`delivered`, `muted`, `canceled`, `synth_failed`, `transport_timeout`,
`transport_failed`); an unknown outcome string fails the row rather than being reported
as a novel success.

## Evidence report

One JSON document per run, written to `$HERALD_STATE_DIR/acceptance/<ts>-<nonce>.json`
unless `--out` says otherwise. Written **always**, including when the harness dies
mid-row.

```
{ schema, run_ts, nonce, live, duration_s, exit_code,
  alignment: { unit_state, running_version, ondisk_version, binary, state_dir,
               kokoro_base_url, playback_host, config_digest,
               playback_host_reachable, passed, reasons[] },
  boundary:  { before: {...}, after: {...} },
  rows: [ { row, name, status, expected, observed, evidence } ],
  notes: [...], verdict, not_exercised[] }
```

The report carries a **sha256 digest** of the shared config file, never its contents,
and no secret values.

## Verdict semantics

The verdict is derived from the rows, never asserted:

- `pass` — every row passed.
- `fail` — any row failed (including a gate 0 abort).
- `partial` — no failures, but at least one row is `blocked` or `not-exercised`; those
  row numbers are listed in `not_exercised`.

A row without evidence is structurally incapable of reporting `pass`. "The playback host
was unreachable" produces `partial`, never a silent green.

## Fail-soft to Herald's callers

The harness is verification tooling and must never degrade the thing it verifies:

- Row 8 mutes; the EXIT trap unmutes unconditionally, so a harness killed mid-row cannot
  leave Herald silent.
- It leaves no spool debris beyond its own clips, which the normal drain consumes.
- It always writes a report file, even on failure.

## Blockers, reported not worked around

| Condition | Result |
|---|---|
| Service not installed/active, or version mismatch | Stop at gate 0, exit non-zero, no audio |
| Playback host unreachable | Boundary rows `blocked`, verdict at best `partial` |
| Kokoro unreachable | Synthesis rows blocked; row 9's malformed checks still run |
| No live authorization | Gate 0 + row 9's no-audio subset only |

## Testing the harness

`tests/acceptance-cancellation.test.sh` covers the harness's own failure modes: syntax,
the explicit-only guarantee, gate 0 aborting on an induced version mismatch
(`HERALD_ACCEPTANCE_BIN` pointed at a stale-reporting stub — nothing deployed is
touched), the report shape, absence of secrets, and that a non-live run plays nothing,
records nothing, and leaves mute off.

It deliberately does **not** exercise the live matrix. A test suite must not be able to
make the house talk.
