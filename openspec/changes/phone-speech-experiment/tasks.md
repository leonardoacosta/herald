# Phone experiment tasks

- [ ] P01 [PS1; depends talk-to-me-attention T01,T02,T03,T04,T06,T08] Obtain selected device/OS/client,
  harmless content/topic and test-window approval. Inspect supported playback/automation,
  Tailscale reachability, iOS upstream wake configuration if applicable, and existing
  permissions read-only. Write a supported/unsupported capability report. No secrets or
  private addresses in committed evidence. Missing selection is a blocker, not a guess.
- [ ] P02 [PS1,PS3; depends P01] Implement repo-owned capability/report seams and tests,
  including unverified/unsupported state and existing text/manual-audio fallback. Verify
  CLI/HTTP public output, upgrade invalidation, failed retrieval, and honest receipt states.
- [ ] P03 [PS2; depends P02 and supported route] Present exact adapter/automation and
  permission changes for activation approval. Implement the selected existing-client route,
  enforce event identity, serialization, policy, expiry and artifact-only playback. Verify
  isolated duplicate, stale event, missing artifact and privacy fixtures before live setup.
  If no supported route exists, stop here and seek explicit unsupported disposition rather
  than inventing a new app, device TTS pipeline or public relay.
- [ ] P04 [PS1,PS2,PS3; depends P03] Run approved real-device acceptance: foreground,
  background, locked, quiet/DND, offline/reconnect, duplicate, expired and synthesis-down.
  Repeat each supported state at least three times. Require observed connected-state
  speech <=15 seconds after publication, zero forbidden speech and zero overlapping or
  duplicate clips. Capture versioned redacted evidence. Fixtures cannot replace hearing
  or device playback evidence. Restore settings if trial fails.
- [ ] P05 [closure; depends P04 or explicit unsupported disposition after P02/P03] Publish
  support matrix, consent/rollback instructions and limits, then present activation status.
  Archive only on successful evidence or an explicit unsupported/deferred disposition.
  Do not claim unsupported trials as delivered autoplay or block unrelated parent channels.
