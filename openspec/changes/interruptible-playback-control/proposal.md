# Proposal: Scoped playback cancellation for interactive briefings

## Change ID

`interruptible-playback-control`

## Status

PROPOSED, refined for implementation

## Depends on

`serial-playback` and `warm-playback` are already archived and define the current spool, resident-player, fallback-drainer, and single-voice invariants. This change extends those protocols. It does not replace them.

## Why

Jcode's rendered-artifact action palette needs explicit Herald briefing actions. Reclicking the active action must stop that action's audio without muting Herald or disturbing unrelated notifications. Herald currently accepts work asynchronously and serializes playback, but an accepted request has no caller-visible identity and the playback protocol carries no safe cancellation identity.

Killing the caller is insufficient: synthesis may already be complete, the service worker may own the job, or audio may already be on the playback host. Global mute is not a substitute because it affects unrelated notifications and does not stop a clip already playing.

## Design

Every accepted notification becomes a request record with an opaque, freshly generated ID. The ID is created before queue insertion and is carried through the service queue, local pipe path, remote spool entry, resident-player control protocol, and history. IDs are opaque strings suitable for JSON and shell transport. They must not contain whitespace, shell metacharacters, path separators, or caller-provided text.

The service remains accept-and-queue: `POST /notify` validates, resolves mute, allocates the ID, enqueues, and returns `202` with the ID before synthesis or delivery. A full queue is rejected as today and is not an accepted request. The local control adapter uses the same submit operation and prints the ID on success; ordinary fire-and-forget callers may ignore it.

Cancellation is a single scoped operation:

- `herald notify stop REQUEST_ID`
- `POST /notify/stop` with `{ "request_id": "..." }`

The operation is bounded, fail-soft, and idempotent. It transitions only the named request. A queued request is marked canceled and never synthesized. A request in synthesis or delivery is canceled if the current stage can observe cancellation. An active clip is interrupted only when the playback host can prove that the active player/spool entry belongs to the requested ID. If that proof or control channel is unavailable, Herald preserves unrelated playback and returns a best-effort result that explicitly says audio was not confirmed stopped.

The remote spool changes from anonymous `clip.*` entries to request-bearing entries or sidecar metadata. The exact filename is an implementation detail, but cancellation must be atomic with respect to enqueue, claim, and deletion. The resident player gets a request-scoped control command that interrupts its current track and removes only the matching pending entry. The fallback drainer remains a safe delivery fallback: it may cancel a pending entry by ID, but must not kill an arbitrary `afplay` process. If it cannot safely interrupt an active fallback clip, it records the limitation and leaves playback alone.

History remains append-only and exactly once per accepted request. Add a closed `canceled` outcome with a reason that distinguishes queued cancellation, interrupted active playback, and cancellation not confirmed at the playback boundary. Repeated stop calls and stops after any terminal outcome return the same stable result without another history row.

## API contract

`POST /notify` success:

```json
{"status":"accepted","request_id":"<opaque-id>"}
```

`POST /notify/stop` success for a known non-terminal request:

```json
{"status":"canceled","request_id":"<opaque-id>","stage":"queued|synthesizing|delivering|playing","stopped":true|false}
```

A known terminal or unknown ID is a successful no-op with the same shape and `stopped:false`; it never affects another request. Malformed IDs/bodies are `400` and do not write history. The CLI emits one stable JSON line by default, with a human-readable mode only if it follows existing CLI conventions.

The submit/stop adapter must not retry cancellation through another transport. Callers stop the exact ID returned by the original submit operation.

## Non-goals

- No global mute behavior.
- No arbitrary queue reordering, priority lane, or deletion of unrelated notifications.
- No second speech or playback implementation.
- No authentication redesign for the existing tailnet-bound service.
- No guarantee that already-completed audio can be retroactively stopped.
- No unsafe process killing when request ownership cannot be proven.
- No persistence guarantee for in-flight requests across playback-host or service restarts beyond the existing spool behavior.

## Definition of Done

- CLI, local control adapter, and HTTP callers can submit, identify, and stop one notification.
- Queued cancellation prevents synthesis and delivery.
- Resident-player cancellation interrupts only the matching active clip and preserves queue order for unrelated clips.
- Fallback playback never becomes silent because cancellation state is ambiguous.
- Every accepted request has exactly one terminal history row, including cancellation races.
- Existing fail-soft bounds, service fallback rules, mute semantics, `--wait`, and single-speech-path rules remain intact.
- Deterministic tests cover API, queue, synthesis, delivery, resident player, fallback drainer, history, and race behavior.
- The Jcode integration contract documents capture-ID, stop-same-ID, no-retry, and best-effort semantics.

## Stop conditions

Stop implementation and return to design if safe request ownership cannot be established at the active playback boundary, if cancellation requires killing an unrelated process or changing global mute state, or if the implementation cannot preserve one terminal history row under acceptance/stop/delivery races.
