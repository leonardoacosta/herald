# Audit reliability follow-ups

Approved by the operator on 2026-09-21: "execute all tasks", referring to the six ranked audit todos.

## Scope
1. Restore hermetic verification and retired Jcode installer tests/docs.
2. Preserve request playback destination for cancellation and report remote confirmation honestly.
3. Connect bounded queue draining and terminalization to production shutdown.
4. Bound HTTP reads and tailnet discovery.
5. Distinguish actual binary artifacts for service-sync restart decisions.
6. Expose history persistence failures without breaking fail-soft delivery.

## Boundaries
Preserve existing target-routing working-tree edits. No real playback, service restart, deployment, or external host contact. Single speech path, exit-0 callers, and no fallback after service acceptance remain unchanged. Tests use isolated state and fake transports.

## Verification
Canonical hermetic shell/Go gate, Go race tests, focused lifecycle/cancellation/build-identity/persistence failure tests. Archive only with re-checkable evidence. No claim of live playback acceptance.
