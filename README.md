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
        → accept + enqueue → 202 (ms)
          → async worker: synth → deliver → append outcome history
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

`202 Accepted` means queued, not synthesized or played. The asynchronous worker appends
its eventual outcome to `${HERALD_STATE_DIR:-~/.local/state/herald}/notify.ndjson` after
synthesis and delivery. A process crash after acceptance but before that append has no durable
queue recovery guarantee. Check history for completed outcomes; do not infer playback from the
acceptance response. The local fail-soft path also bounds synthesis and playback, and records
synthesis, transport, timeout, and missing-binary failures. Local delivery still plays on the
configured playback host; there is no local-device playback path or compatibility alias for an
older transport.

Configuration is ONE shared file, `${HERALD_CONFIG_DIR:-~/.config/herald}/config`, read by
BOTH halves of the pipeline: `bin/lib.sh` via `source` for every CLI/pipe invocation, and the
`herald-notify.service` unit via systemd's `EnvironmentFile=`. Precedence is environment, then
that file, then the documented default:

| Environment | Config key | Default |
| --- | --- | --- |
| `HERALD_KOKORO_BASE_URL` | `NOTIFY_KOKORO_BASE_URL` | `http://127.0.0.1:8880` |
| `HERALD_NOTIFY_PLAYBACK_HOST` | `NOTIFY_PLAYBACK_HOST` | `mac` |
| `HERALD_NOTIFY_CLIENT_TARGETS` | `HERALD_NOTIFY_CLIENT_TARGETS` | unset |
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

Requests may include a client identity in `target` (or the compatibility field `client`).
Herald resolves that identity through the optional `HERALD_NOTIFY_CLIENT_TARGETS` mapping,
formatted as comma-separated `identity=ssh-host` pairs, for example
`laptop=bb-mac,phone=phone-host`. Set it in the shared deployment file at
`${HERALD_CONFIG_DIR:-~/.config/herald}/config`, not in a request and not in committed source.
Identity names follow the request grammar: 1–63 ASCII characters, start with an alphanumeric
character, then use only alphanumerics, `.`, `_`, or `-`. Hosts must be nonempty SSH names or
aliases, cannot start with `-`, and cannot contain whitespace. Duplicate keys, empty entries
(including a trailing comma), and malformed entries invalidate the entire mapping. Entries
split on the first equals sign. The request never supplies an SSH host. An unknown or absent
identity, or an invalid mapping, uses the configured static playback host. Configured identities
map to deployment-owned SSH hosts. Run `bin/verify-targets.sh` after editing to validate the
mapping without contacting any host, then restart `herald-notify.service`.

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

## Verification

Run `./bin/verify.sh` for the canonical local and CI gate. It builds one fresh `bin/herald`
artifact in temporary storage, runs `go test ./...`, mapping validation, and the explicit
hermetic shell-test allowlist. The gate does not read or replace an executable
`bin/herald` from the repository or contact live playback providers. `bin/verify-targets.sh`
checks the deployed mapping without contacting a host. Live/deployed acceptance and audition
scripts remain excluded.

## Status

The core pipe extraction, voice management, plugin, quality, briefing, playback, cancellation, and Jcode integration work is implemented and archived. Current approved work and this reliability change are:

1. [`talk-to-me-attention`](openspec/changes/talk-to-me-attention/proposal.md) — event identity, attention policy, channels and skill; ordered tasks in its proposal
2. [`phone-speech-experiment`](openspec/changes/phone-speech-experiment/proposal.md) — depends on the parent attention-channel contracts; device capability and acceptance gates remain explicit
3. [`harden-notify-boundaries`](openspec/changes/archive/2026-09-23-harden-notify-boundaries/proposal.md) — implemented reliability improvements for shell options, hermetic verification, target validation, history reads and operator docs

See each proposal's task checklist for current implementation status. Proposal approval does not imply deployment or live-device acceptance.
