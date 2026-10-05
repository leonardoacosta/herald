# explain-tts pipeline reference

Read before editing the transport, debugging a silent miss, or changing config precedence.

## Wire contract (live-verified 2026-08-25)

Server: remsky/kokoro-fastapi-cpu v0.6.0, compose in the herald repo. Unauthenticated;
tailnet-bound; CPU-only; cold start ~8s after boot.

- `POST {BASE_URL}/v1/audio/speech` body `{"model":"kokoro","input":...,"voice":...,"speed":F,"response_format":"mp3"}` -> binary MP3 (128kbps 24kHz mono), warm ~0.5s.
- `GET /health` ~1ms. `GET /v1/audio/voices` -> `{voices:[{id,name}]}`, 68 entries.
- Voice syntax: ids or weighted blends `af_heart+af_bella(2)`; speed clamped 0.5-2.0.

## Config precedence

Baked defaults in `lib/config.sh` <- `~/.config/explain-tts/config.sh` (unmanaged, survives
skill updates). `options.env` next to it holds user options (VOICE, SPEED, MUTE_UNTIL),
seeded once, written atomically (mktemp+mv). History:
`~/.local/state/explain-tts/history.ndjson`.

## Transport

1. The synthesized binary response is retained on the **originating client** and played there:
   macOS uses `afplay`; Linux uses the first available `paplay`, `pw-play`, `mpv`, or `ffplay`;
   Windows-compatible shells use PowerShell `SoundPlayer` when available.
2. Optional fallback only when `EXPLAIN_TTS_REMOTE_FALLBACK=1`: the ENTIRE
   `lib/remote-receiver.sh` is sent as the ssh command string,
   `timeout $PLAYBACK_TIMEOUT ssh -o BatchMode=yes -o ConnectTimeout=6 <ssh_host> "$CMD"`
   with the clip on stdin. No `ssh -n` (it would eat stdin). Exit codes: 0 delivered,
   124 transport_timeout (host asleep/unreachable), other transport_failed.
3. Receiver drops the clip into `/tmp/herald-spool` (Herald-shared), nudges the resident
   player fifo when alive, else spawns one mkdir-lock drainer that afplays the batch
   oldest-first. Serialization against Herald notifications is inherited from the shared
   spool protocol.

## Concurrency

Local synthesis serializes through an mkdir lock in the state dir (bounded wait, fail-open).
The remote spool lock serializes playback. Never call tts-say from hooks with background
execution: task-result notifications re-trigger responses and loop.

## Debugging a missing spoken explanation

1. `bin/tts-selftest` -- health, voice count, latency, last history rows.
2. Read the history board: delivered / muted / dry_run absent / synth_failed /
   transport_timeout / transport_failed tell you which leg failed.
3. `curl -s --max-time 5 $BASE_URL/health` by hand if health shows down.
4. `ssh -o BatchMode=yes $SSH_HOST echo ok` if transport rows repeat.
5. Check `~/.config/explain-tts/options.env` for an accidental `MUTE_UNTIL` in the future.

Never reproduce secret values while debugging; service addresses are config facts.
