# herald

Single-responsibility notification service for Leo's agent fleet. Herald owns every channel
that gets an operator's attention: the spoken TTS pipe (Kokoro synthesis on the homelab,
playback on the Mac), the Moshi mobile hook wiring, notification history, and the control
surface (`/notify`) that harnesses import as a plugin.

## Why this repo exists

Before herald, the notification pipeline was split across three repos with no single owner:

- `~/dev/cc/scripts/lib/notify.sh` — the `say_notify` shell helper (caller side)
- `~/dev/personal/herdr-shepherd/bin/notify.sh` + `plugins/herdr-state/pkg/notify/` — transport,
  voice resolution, Kokoro synthesis client, history
- `~/dev/personal/herdr-shepherd/compose/kokoro.yml` + `bin/kokoro-sync.sh` — the synthesis service

Herald extracts the pipeline into one repo with one responsibility, consumed by all three
harnesses (claude/cc, codex, pi) as a plugin.

## Architecture (target)

```
Harness hook or inline Bash
  → say_notify "text"              (plugin/lib, preloaded via BASH_ENV in cc)
    → $HERALD/bin/notify.sh        (argument handling + ssh transport)
      → herald notify              (Go: voice resolution, synthesis, history)
        → Kokoro-FastAPI           (homelab, compose module owned here)
          → playback host          (ssh + afplay)

Harness hook events
  → moshi-hook {claude,codex,pi}-hook   (Moshi mobile app: inbox, Live Activities, approvals)
```

## Use

Build the internal CLI once, then call the fail-soft pipe:

```sh
go build -o bin/herald ./cmd/herald
bin/notify.sh -p <project-code> "message"
bin/notify.sh --wait -p <project-code> "playback evidence"
```

`bin/notify.sh` always exits 0 and bounds synthesis and playback. Every non-empty
attempt appends exactly one record to
`${HERALD_STATE_DIR:-~/.local/state/herald}/notify.ndjson`, including synthesis,
transport, timeout, and missing-binary failures. There is no local playback path
or compatibility alias for an older transport.

Configuration precedence is environment, optional
`${HERALD_CONFIG_DIR:-~/.config/herald}/config`, then the documented default:

| Environment | Config key | Default |
| --- | --- | --- |
| `HERALD_KOKORO_BASE_URL` | `NOTIFY_KOKORO_BASE_URL` | `http://127.0.0.1:8880` |
| `HERALD_NOTIFY_PLAYBACK_HOST` | `NOTIFY_PLAYBACK_HOST` | `mac` |
| `HERALD_NOTIFY_PLAYBACK_TIMEOUT` | `NOTIFY_PLAYBACK_TIMEOUT` | `10` seconds |
| `HERALD_NOTIFY_SYNTH_TIMEOUT` | `NOTIFY_SYNTH_TIMEOUT` | `30` seconds |

Legacy `HERDR_*` notification variables remain fallback reads for one release.
Service lifecycle is managed by `bin/kokoro-sync.sh`; the committed Compose module
requires `KOKORO_BIND_TAILSCALE_IP` and never embeds a host address.

### Voice management

The same binary exposes read/manage seams for operator surfaces:

```sh
bin/herald notify voices --json
bin/herald notify catalog --json
bin/herald notify audition --voice kokoro:af_bella
bin/herald notify set --project hs --voice kokoro:af_bella
bin/herald notify reset --project hs
```

Project choices come from `HERALD_PROJECTS_TOML`, the one-release
`SHEPHERD_PROJECTS_TOML` fallback, `$DOTFILES/home/projects.toml`, or the installfest
default, in that order. Reads and normal notification resolution never require the
catalog. New Kokoro assignments are catalog-validated and written atomically at mode
0600; legacy bare values and unrelated mappings are preserved. Audition always uses a
fixed harmless sentence, discards the audio, and never writes notification history or
contacts the playback host.

## Status

The core pipe extraction is implemented and archived. See `openspec/changes/` for the
remaining feature proposals in dependency order:

1. `voice-management-core` — safe voice discovery, audition, and mapping management
2. `herald-cc-plugin` — plugin packaging + the rebuilt `/notify` control surface
3. `voice-quality` — speed, voice blending, normalization, speakable-text rules
4. `deep-briefings` — on-demand long-form spoken summaries
5. `moshi-hook-parity` — event-coverage parity across claude/codex/pi
