# Proposal: Re-validate deployed cancellation and playback acceptance end to end

## Change ID

`revalidate-cancellation-playback-acceptance`

## Status

PROPOSED

## Depends on

Archived changes `serial-playback`, `warm-playback`, and `interruptible-playback-control`
define the behaviors under validation. This change implements **no new playback or
cancellation behavior**. It is an independent verification/operations feature: a
repeatable acceptance protocol plus its runner, evidence contract, and reporting.

## Why

`interruptible-playback-control` shipped with a one-time real acceptance run (its task
6.4). That evidence is point-in-time: it does not prove the *currently deployed*
service, on-disk binary, shared config file, resident player on the Mac playback host,
and spool protocol still cooperate after subsequent rebuilds, restarts, or config
edits. AGENTS.md establishes that "rebuilding `bin/herald` does not reach the running
service by itself" and that history is the debugging surface. Herald therefore needs a
named, rerunnable acceptance validation that produces durable evidence that scoped
cancellation and serialized playback still work against the real deployed pipeline,
not fakes.

## What this change is

A validation harness (`tests/acceptance-cancellation.sh` or equivalent under `tests/`,
name final at implementation) plus documentation that:

1. Checks preconditions and version alignment before touching audio.
2. Executes a bounded, non-destructive test matrix against the deployed service and
   real playback host.
3. Correlates every step against history records by request ID.
4. Emits one machine-readable evidence report per run.

It is explicit-only: run by an operator on demand. Never wired into hooks, schedules,
CI without opt-in, or agent completion events (consistent with the briefings-are-
explicit-only rule).

## Version and deployment alignment (gate 0)

The run aborts (cleanly, exit non-zero, no audio played) unless all hold:

- `herald-notify.service` is active and `/health` responds within its bound.
- Running service version (from `/health`) equals on-disk `bin/herald` version (from
  `herald notify status --json`), using the same comparison `bin/service-sync.sh`
  already performs. Mismatch is reported as "stale service, re-run service-sync",
  never auto-restarted by the harness.
- The shared config file (`${HERALD_CONFIG_DIR:-~/.config/herald}/config`) resolves to
  the same state dir and Kokoro URL the harness itself resolves, so the
  config-divergence bypass in `bin/notify.sh` cannot silently reroute test traffic.
- The playback host is reachable and the resident player lock state is readable.

The alignment result (versions, git SHA if embedded, config digest, bind posture) is
the first section of the evidence report.

## Mac resident-player boundary

The playback host is observed, not mutated:

- The harness never installs, restarts, or kills `bin/herald-player.sh`, its launchd
  agent, or any `afplay` process. Player lifecycle stays owned by `bin/player-sync.sh`.
- Evidence at the boundary is read-only: spool directory listing before/after,
  lock-holder identity, request-ID metadata presence, and player log tail if
  available.
- Both delivery modes are in scope but the harness only *records* which one served
  each clip (resident player vs fallback drainer); it does not force a mode by killing
  the player. If only one mode is live during the run, the report says so and the
  other mode's rows are marked `not-exercised`, not passed.
- "Audio actually played" is evidenced by, in preference order: player/drainer log
  entry for the clip, spool entry consumed, and `--wait` return within bound. Human
  ear confirmation is optional corroboration, never the only evidence.

## Test matrix

All utterances are short, harmless, and self-identifying (include the request ID or a
run nonce in the text). Each row records: request ID, transport used, expected
outcome, observed outcome, history row, and boundary evidence.

| # | Case | Path | Expected |
|---|------|------|----------|
| 1 | Plain notify via service | `bin/notify.sh` → `POST /notify` | `202` + request_id, one `delivered` history row, clip served once |
| 2 | Notify with `--wait` | local path (service bypassed by design) | exits 0 within bound, one history row, no double-speak |
| 3 | Queued cancellation | submit then immediately `herald notify stop ID` | `canceled` history row, no synthesis/delivery evidence |
| 4 | Active-playback cancellation | submit a longer clip, stop while playing | stop returns `stopped:true` only with ownership proof; clip audibly/observably interrupted; one `canceled` row |
| 5 | Unrelated survival | submit A and B, stop A during playback | B still plays completely; B has `delivered` row |
| 6 | Stop idempotency / unknown ID | repeat stop of terminal ID, stop random ID | stable no-op result, `stopped:false`, no new history rows |
| 7 | Serialization under concurrency | two near-simultaneous notifies | both delivered, never mixed, arrival order preserved |
| 8 | Mute respected | mute, notify, unmute | `muted` history row, no boundary evidence of playback |
| 9 | HTTP contract spot-checks | raw `curl` of `/notify` and `/notify/stop` | documented status/body shapes for accepted, malformed, unknown |

Rows 4 and 5 are the core of the restored acceptance from the prior 6.4. Row 8 must
end with mute state restored even on failure (trap-based cleanup).

## Telemetry / history requirements

- Every accepted request in the run maps to **exactly one** terminal history row,
  verified by querying `herald notify history` filtered to the run window and matching
  by request ID. Zero rows or duplicate rows fail the row.
- Outcomes must come from the closed set (delivered, muted, canceled with reason,
  synth_failed, transport_timeout, transport_failed). Unknown outcome strings fail.
- The evidence report is one JSON (or JSONL) file written under
  `$HERALD_STATE_DIR/acceptance/` (or a `--out` path): run timestamp, alignment
  section, per-row records with raw responses, history rows, boundary evidence, and a
  final verdict `pass | fail | partial(not-exercised rows listed)`.
- The report contains no secret values and no full config dump beyond digests and the
  non-secret keys already surfaced by `notify status`.

## Blockers (declared, must be reported not worked around)

- Service unit not installed/active, or version mismatch: report and stop at gate 0.
- Playback host unreachable over SSH/tailnet: rows needing boundary evidence become
  `blocked`, run verdict at best `partial`.
- Kokoro unreachable: synthesis-dependent rows blocked; row 9's malformed-request
  checks can still run.
- Real audio output requires operator authorization (someone is in the room / it is
  acceptable to make sound). The harness requires an explicit `--live` flag; without
  it, it performs gate 0 plus row 9 only.

## Non-goals

- No new playback, cancellation, queueing, or history behavior; no API changes.
- No load or soak testing; concurrency is limited to the two-clip serialization row.
- No mutation of the playback host, launchd agents, systemd units, or shared config.
- No CI scheduling, hook wiring, or automatic periodic runs.
- No re-validation of voice quality, briefing content, or Kokoro model behavior.
- No second speech path: the harness only calls existing entry points.

## Acceptance criteria (measurable)

1. Two consecutive `--live` runs on the deployed system produce `pass` verdicts with
   all 9 rows exercised (or documented `partial` with only host-availability blocks).
2. Gate 0 correctly fails when a version mismatch is induced non-destructively
   (e.g., pointing the harness at a copied stale binary via env override), without
   playing audio.
3. For every accepted request across a run, exactly one terminal history row exists;
   the report proves it by ID.
4. Row 5 demonstrates, in one run's evidence, that cancelling A did not silence or
   reorder B.
5. The harness itself is fail-soft to Herald's callers: it never leaves mute on, never
   leaves spool debris (its own clips only), and always writes a report file even on
   failure.
6. Total `--live` runtime is bounded (target under 3 minutes) and each network call
   has an explicit timeout.

## Spec delta

None. This change adds verification/operations tooling for behavior already specified
in `openspec/specs/notify-pipeline/spec.md`; it introduces no new requirements on the
pipeline itself. If implementation reveals an underspecified observable behavior
(e.g., history query filtering), a delta will be added at that point rather than
speculatively now.

## Stop conditions

Stop and return to design if validation cannot be made non-destructive (requires
killing the player or restarting the service to observe an outcome), or if evidence
for "clip actually played" cannot be obtained read-only at the playback boundary.
