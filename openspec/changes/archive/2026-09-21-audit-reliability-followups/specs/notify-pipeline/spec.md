# Reliability follow-up requirements

## ADDED Requirements

### Requirement: Notification service shutdown is bounded and records accepted work
The service SHALL stop HTTP admission, drain accepted jobs for a bounded interval, and cancel remaining work while allowing one terminal history append per accepted job. The total normal cleanup budget SHALL fit the systemd stop deadline. Forced process death or uninterruptible filesystem I/O cannot guarantee persistence and SHALL NOT be described as durable replay.

### Requirement: Stop uses the accepted playback destination
Requests SHALL retain the resolved delivery configuration at acceptance. Delivery and cancellation SHALL use that same destination. Duplicate terminal stops SHALL not contact playback. A local cancellation signal or successful SSH exit alone SHALL NOT count as confirmation that physical playback stopped. Ambiguous resident/drainer ownership SHALL suppress a positive acknowledgement while preserving unrelated clips.

### Requirement: History persistence failure is observable
A failed terminal append SHALL increment a non-secret health counter and emit a generic diagnostic without retrying a possibly partial append. Later notifications SHALL continue processing. Successful persistence remains exactly one append per attempt.

### Requirement: Network input and address discovery are bounded
The production HTTP server SHALL bound header/body/idle reads. Tailnet discovery SHALL have a wall-clock deadline, including subprocess pipe cleanup. Slow clients SHALL not block unrelated health requests.

### Requirement: Service identity distinguishes running artifacts
Version identity SHALL incorporate a cached digest of the running artifact, not merely the source revision and dirty flag. Replacing an on-disk executable SHALL NOT change the old process's identity. A distinct artifact SHALL cause the existing service-sync comparison to detect a mismatch.

### Requirement: Canonical verification is independent of deployed mapping
Verification SHALL validate target mapping in an isolated environment. Retired automatic Jcode installation SHALL be tested as a no-op; removal SHALL be tested using prewired fixtures without enabling retired hooks.
