# Proposal: Scoped playback cancellation for interactive briefings

## Change ID

`interruptible-playback-control`

## Status

PROPOSED

## Why

Jcode's rendered-artifact action palette now needs two explicit Herald briefing actions: a one-sentence orientation and a step-by-step explanation. Reclicking the active action must stop the current audio immediately. Herald currently accepts notifications and queues them, but exposes no request identity or scoped cancellation operation. Killing the caller cannot stop audio already synthesized or queued on the remote playback host, and global mute is not a valid substitute.

## What Changes

- Assign a stable request ID to every accepted notify request.
- Return the request ID from the local CLI/pipe and `POST /notify` acceptance response.
- Add an idempotent scoped stop operation for one request ID.
- Cancel queued work before synthesis when possible.
- Interrupt the matching active playback clip when the playback host supports it.
- Record one terminal history outcome for cancellation without creating duplicate speech or duplicate history rows.
- Add a thin `say_stop`/control adapter suitable for Jcode and other external callers.

## Non-goals

- No global mute behavior.
- No arbitrary queue reordering or deletion of unrelated notifications.
- No second speech or playback implementation.
- No authentication redesign for the existing tailnet-bound service.
- No guarantee that already-completed audio can be retroactively stopped.

## Integration contract

Jcode must be able to treat cancellation as best-effort and idempotent. An unknown, already-completed, or already-canceled request returns a stable no-op result. Jcode must not retry a cancellation through another path.

## Definition of Done

- CLI and HTTP callers can submit, identify, and cancel one notification.
- Active and queued cancellation behavior is covered with deterministic tests.
- The remote playback path stops only the requested clip and preserves unrelated queue entries.
- History contains exactly one terminal record per accepted request.
- Fail-soft and bounded-time guarantees remain intact.
- The contract is documented for Jcode's artifact-action integration.

## Stop conditions

- The playback host cannot provide a safe request-scoped interruption primitive.
- Implementing cancellation would require killing an unrelated playback process or mutating global mute state.
- The service cannot preserve exactly-once history semantics under cancellation races.
