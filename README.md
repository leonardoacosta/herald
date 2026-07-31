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

## Status

Bootstrapping. See `openspec/changes/` for the extraction and feature proposals, in dependency
order:

1. `extract-notify-pipeline` — move the pipe, Go package, and Kokoro module here
2. `herald-cc-plugin` — plugin packaging + the rebuilt `/notify` control surface
3. `voice-quality` — speed, voice blending, normalization, speakable-text rules
4. `deep-briefings` — on-demand long-form spoken summaries
5. `moshi-hook-parity` — event-coverage parity across claude/codex/pi
