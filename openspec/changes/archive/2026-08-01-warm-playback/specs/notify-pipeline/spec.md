# notify-pipeline Spec Delta — warm-playback

## MODIFIED Requirements

### Requirement: One notification plays at a time

The playback host SHALL play at most one notification clip at any moment. Concurrent notify
calls SHALL be spooled and played in arrival order rather than mixed, and no clip SHALL be
discarded because another was playing when it arrived.

Serialization SHALL fail toward sound: any ambiguous lock state resolves to playing the clip,
never to suppressing it.

Playback SHALL begin without a perceptible delay attributable to acquiring the audio device.
A resident player MAY hold the output device open to achieve this, and SHALL release it after
an idle window. Whatever plays the spool, delivery SHALL NOT depend on it being healthy: if a
resident player is absent or wedged, clips SHALL still play.

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

#### Scenario: Sequential notifications start promptly

- **WHEN** two notify calls arrive several seconds apart, far enough that they cannot batch
- **THEN** neither is preceded by an audible device-acquisition pause

#### Scenario: A missing resident player is not a silence

- **WHEN** no resident player is running or it fails to start
- **THEN** the spool is still drained and the audio still plays
