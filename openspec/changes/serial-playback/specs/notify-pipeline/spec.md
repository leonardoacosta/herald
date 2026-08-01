# notify-pipeline Spec Delta — serial-playback

## ADDED Requirements

### Requirement: One notification plays at a time

The playback host SHALL play at most one notification clip at any moment. Concurrent notify
calls SHALL be spooled and played in arrival order rather than mixed, and no clip SHALL be
discarded because another was playing when it arrived.

Serialization SHALL fail toward sound: any ambiguous lock state resolves to playing the clip,
never to suppressing it.

#### Scenario: Concurrent calls do not overlap

- **WHEN** two notify calls deliver audio within the playback window of each other
- **THEN** the second clip begins only after the first finishes, and both are played

#### Scenario: A clip arriving mid-playback extends the stream

- **WHEN** audio is already playing and a new clip is spooled
- **THEN** it plays immediately after the current clip, with no second player process started

#### Scenario: A dead player never mutes the host

- **WHEN** the process draining the spool dies mid-clip, leaving its lock behind
- **THEN** the next notify call breaks the stale lock and its audio plays

#### Scenario: The uncontended path is unchanged

- **WHEN** a single notify call arrives with an empty spool and no drainer running
- **THEN** it plays without waiting, and the pipe still records `delivered` on the same terms
