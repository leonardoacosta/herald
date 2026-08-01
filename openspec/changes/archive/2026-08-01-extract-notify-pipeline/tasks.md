# Tasks — extract-notify-pipeline

## 1. Herald skeleton

- [x] 1.1 `go mod init` at repo root; create `cmd/herald/main.go` dispatching to
      `pkg/notify` CLI (mirror herdr-shepherd `plugins/herdr-state/cmd/herdr-state/`).
      Verify: `go build ./...` exits 0.
- [x] 1.2 Copy `pkg/notify/{voice,kokoro,store,cli}.go` + `*_test.go` from herdr-shepherd
      `531863a` `plugins/herdr-state/pkg/notify/`; adjust package import paths only.
      Verify: `go test ./pkg/notify/` passes (same assertions, zero edits to test logic).
- [x] 1.3 Create `bin/lib.sh` with ONLY `shepherd_config` (rename `herald_config`),
      state-dir resolution (`$HERALD_STATE_DIR`, default `~/.local/state/herald`), and
      `herald_bin`. Verify: `bash -n bin/lib.sh`.

## 2. Move the pipe and the Kokoro module

- [x] 2.1 Copy `bin/notify.sh` from herdr-shepherd; replace `herdr-state notify` calls with
      `herald notify`, `lib.sh` sourcing with herald's. Preserve every comment block — the
      four delivery constraints (`notify.sh:105-134`) are measured facts, not prose.
      Verify: `bash -n`, then `HERALD_KOKORO_BASE_URL= bin/notify.sh "x"` exits 0 and
      appends `synth_failed`.
- [x] 2.2 Copy `compose/kokoro.yml` + `bin/kokoro-sync.sh`; rename env prefix
      `SHEPHERD_KOKORO_*` → `HERALD_KOKORO_*` keeping the old names as fallbacks for one
      release. Verify: `bin/kokoro-sync.sh --diff` against the live homelab shows only the
      env-name comment delta.
- [x] 2.3 Migrate state: copy `voices.json` + `notify.ndjson` into `$HERALD_STATE_DIR`.
      Verify: `herald notify record --project test ...` appends to the new path.

## 3. Repoint consumers

- [x] 3.1 cc `scripts/lib/notify.sh`: `_notify_pipe()` resolves `$HERALD/bin/notify.sh`
      (drop `$HERDR_SHEPHERD`); update the header comment and
      `skills/deploy-and-env/references/notifications.md` diagram. Verify:
      `grep -n HERDR_SHEPHERD scripts/lib/notify.sh` empty;
      `say_notify "repointed"` speaks (evidence: new `delivered` record).
- [x] 3.2 Export `$HERALD` where `$HERDR_SHEPHERD` is exported today (installfest/chezmoi
      env template — locate with `grep -rn HERDR_SHEPHERD` in the dotfiles repo).
- [x] 3.3 herdr-shepherd: point `bin/notify-pane.sh` at herald's `notify.ndjson` path.
      Verify: pane renders existing history.

## 4. Delete the old owner (gated)

- [x] 4.1 Disposition resolved (split — see proposal § Known collision): coordinate with
      `voice-management-core` task 3.1 so the herdr-shepherd change is slimmed to dock-UI
      scope in the same window `pkg/notify` is deleted there. Verify: the slimmed
      proposal no longer cites `plugins/herdr-state/pkg/notify` paths.
- [x] 4.2 Delete moved files from herdr-shepherd; drop `pkg/notify` + the `notify`
      subcommand from `herdr-state`. Verify: `go build ./...` in herdr-shepherd passes;
      repo-wide grep for `pkg/notify` clean outside archives.
- [x] 4.3 Update cc spec `openspec/specs/notify-transport/spec.md` delivery description
      (herdr pipe → herald pipe) via a cc-side spec delta. Verify: cc `validate-cc`
      notify-related ratchet rows still pass.

## 5. Evidence

- [x] 5.1 One `--wait` end-to-end run recorded in the PR/commit description: text →
      synthesis → playback, plus the `delivered` history line.

- [x] 5.2 Resolve the central-claude `repo-backup-single-copy` gate recorded in
      `decisions.jsonl`. The ratchet was superseded by the archived
      `retire-repo-backup-global-ratchet` change and now emits INFO without blocking
      unrelated closure. Fresh central validation passed with `Errors: 0 Warnings: 0`;
      the recorded consumer commit remains an ancestor of `main` with every authorized
      path unchanged.

## Evidence — 2026-08-01

- Herald: Go tests/build, Bash syntax, ShellCheck, Compose config, forced-failure
  smoke, strict OpenSpec validation, and diff checks passed.
- State: 337 historical records migrated at mode 0600; a Herald CLI verification
  append landed in the new file. No source history contents were reproduced.
- Live pipe: a `--wait` call appended one `delivered` record for project `herald`.
- herdr-shepherd: Go tests, 14-case resume watcher self-test, read-only board
  render, Bash checks, and both strict OpenSpec validations passed; local-only
  commit `87596f09645dd4a5f25a0e2a52a44d978cd7c01d`.
- central-claude: focused JSON/Bash checks, live `say_notify` delivery, and all
  strict OpenSpec validations passed; local-only commit
  `de253da6d02ea4164aed7f9dc4c51437ead4dd5c`. Fresh focused validation now
  passes every blocking ratchet after `repo-backup-single-copy` was demoted to INFO.
  The 2026-08-01 completion run reported `Errors: 0 Warnings: 0`, and strict OpenSpec
  validation passed 108/108 items.
