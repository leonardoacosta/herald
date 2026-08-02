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

## Architecture

Herald is a resident service (`herald notify serve`) with the CLI/pipe kept as its fallback
transport. `bin/notify.sh` posts to the service first; it falls through to the local path
ONLY when the service was never reached — never on a slow or erroring response, which the
service may have already recorded. `POST /notify` accepts and queues rather than completing
synchronously: synthesis (2.5-8.5s) and delivery run async after the `202`, because a
synchronous response can time the caller out after delivery already happened and double-speak
through the fallback. See `AGENTS.md` for the full fallback guarantee and bind posture.

```
Harness hook or inline Bash
  → say_notify "text"                     (plugin/lib, preloaded via BASH_ENV in cc)
    → $HERALD/bin/notify.sh               (argument handling; service client first)

      ── primary: service reachable ──────────────────────────────────────────
      → POST /notify (herald notify serve, loopback + tailnet, :8881)
        → accept + enqueue → 202 (ms)      (history record written here)
          → async worker: synth → deliver
            → Kokoro-FastAPI               (homelab, compose module owned here)
              → playback host              (ssh + afplay)

      ── fallback: service unreachable only ──────────────────────────────────
      → herald notify                     (Go: voice resolution, synthesis, history)
        → Kokoro-FastAPI                  (homelab, compose module owned here)
          → playback host                 (ssh + afplay)

Operator / any tailnet caller (e.g. pi)
  → POST /mute, /unmute, GET /status, GET /history?n=   (herald notify serve control surface)

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

Configuration is ONE shared file, `${HERALD_CONFIG_DIR:-~/.config/herald}/config`, read by
BOTH halves of the pipeline: `bin/lib.sh` via `source` for every CLI/pipe invocation, and the
`herald-notify.service` unit via systemd's `EnvironmentFile=`. Precedence is environment, then
that file, then the documented default:

| Environment | Config key | Default |
| --- | --- | --- |
| `HERALD_KOKORO_BASE_URL` | `NOTIFY_KOKORO_BASE_URL` | `http://127.0.0.1:8880` |
| `HERALD_NOTIFY_PLAYBACK_HOST` | `NOTIFY_PLAYBACK_HOST` | `mac` |
| `HERALD_NOTIFY_PLAYBACK_TIMEOUT` | `NOTIFY_PLAYBACK_TIMEOUT` | `10` seconds |
| `HERALD_NOTIFY_SYNTH_TIMEOUT` | `NOTIFY_SYNTH_TIMEOUT` | `30` seconds |
| `HERALD_NOTIFY_PORT` | — | `8881` |
| `HERALD_STATE_DIR` | — | `~/.local/state/herald` |
| `HERALD_PROJECTS_TOML` | — | see "Voice management" below |

The file is plain `KEY=value` — the intersection of what bash `source` and systemd's
`EnvironmentFile=` both accept, which is what lets one file drive both readers identically. No
shell: no `export`, no quoting, no expansion, no trailing inline comment after a value — either
of those would parse fine under `source` and silently diverge under systemd. `HERALD_*` names
only; the "Config key" column above is a one-release legacy layer this file does not use.
`bin/service-sync.sh` seeds the file once, at install, with the values in effect at that
moment, and never overwrites it again. To change a deployed value: edit the file, then
`systemctl --user restart herald-notify.service` — `bin/service-sync.sh` is not part of that
loop. A value explicitly exported in a caller's own environment still overrides the file for
that one invocation.

A caller whose own resolved state dir or Kokoro URL disagrees with what the file declares
bypasses the service and runs the local path instead of handing the request to an instance
that would synthesize or record it somewhere unexpected. See `AGENTS.md` for the full
contract, including the escape hatch for a caller deliberately pointed at a different service.

Legacy `HERDR_*` notification variables remain fallback reads for one release.
Kokoro's own service lifecycle is managed separately by `bin/kokoro-sync.sh`; the committed
Compose module requires `KOKORO_BIND_TAILSCALE_IP` and never embeds a host address.

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
