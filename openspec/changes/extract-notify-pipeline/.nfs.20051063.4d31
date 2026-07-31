# Tasks — extract-notify-pipeline

## 1. Herald skeleton

- [ ] 1.1 `go mod init` at repo root; create `cmd/herald/main.go` dispatching to
      `pkg/notify` CLI (mirror herdr-shepherd `plugins/herdr-state/cmd/herdr-state/`).
      Verify: `go build ./...` exits 0.
- [ ] 1.2 Copy `pkg/notify/{voice,kokoro,store,cli}.go` + `*_test.go` from herdr-shepherd
      `531863a` `plugins/herdr-state/pkg/notify/`; adjust package import paths only.
      Verify: `go test ./pkg/notify/` passes (same assertions, zero edits to test logic).
- [ ] 1.3 Create `bin/lib.sh` with ONLY `shepherd_config` (rename `herald_config`),
      state-dir resolution (`$HERALD_STATE_DIR`, default `~/.local/state/herald`), and
      `herald_bin`. Verify: `bash -n bin/lib.sh`.

## 2. Move the pipe and the Kokoro module

- [ ] 2.1 Copy `bin/notify.sh` from herdr-shepherd; replace `herdr-state notify` calls with
      `herald notify`, `lib.sh` sourcing with herald's. Preserve every comment block — the
      four delivery constraints (`notify.sh:105-134`) are measured facts, not prose.
      Verify: `bash -n`, then `HERALD_KOKORO_BASE_URL= bin/notify.sh "x"` exits 0 and
      appends `synth_failed`.
- [ ] 2.2 Copy `compose/kokoro.yml` + `bin/kokoro-sync.sh`; rename env prefix
      `SHEPHERD_KOKORO_*` → `HERALD_KOKORO_*` keeping the old names as fallbacks for one
      release. Verify: `bin/kokoro-sync.sh --diff` against the live homelab shows only the
      env-name comment delta.
- [ ] 2.3 Migrate state: copy `voices.json` + `notify.ndjson` into `$HERALD_STATE_DIR`.
      Verify: `herald notify record --project test ...` appends to the new path.

## 3. Repoint consumers

- [ ] 3.1 cc `scripts/lib/notify.sh`: `_notify_pipe()` resolves `$HERALD/bin/notify.sh`
      (drop `$HERDR_SHEPHERD`); update the header comment and
      `skills/deploy-and-env/references/notifications.md` diagram. Verify:
      `grep -n HERDR_SHEPHERD scripts/lib/notify.sh` empty;
      `say_notify "repointed"` speaks (evidence: new `delivered` record).
- [ ] 3.2 Export `$HERALD` where `$HERDR_SHEPHERD` is exported today (installfest/chezmoi
      env template — locate with `grep -rn HERDR_SHEPHERD` in the dotfiles repo).
- [ ] 3.3 herdr-shepherd: point `bin/notify-pane.sh` at herald's `notify.ndjson` path.
      Verify: pane renders existing history.

## 4. Delete the old owner (gated)

- [ ] 4.1 STOP-gate: confirm with Leo the disposition of open change
      `add-notify-voice-management` (retarget to herald | park). Do not proceed unanswered.
- [ ] 4.2 Delete moved files from herdr-shepherd; drop `pkg/notify` + the `notify`
      subcommand from `herdr-state`. Verify: `go build ./...` in herdr-shepherd passes;
      repo-wide grep for `pkg/notify` clean outside archives.
- [ ] 4.3 Update cc spec `openspec/specs/notify-transport/spec.md` delivery description
      (herdr pipe → herald pipe) via a cc-side spec delta. Verify: cc `validate-cc`
      notify-related ratchet rows still pass.

## 5. Evidence

- [ ] 5.1 One `--wait` end-to-end run recorded in the PR/commit description: text →
      synthesis → playback, plus the `delivered` history line.
