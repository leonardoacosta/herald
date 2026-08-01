package notify

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Mute state: the operator's "stop talking for a while" switch.
//
// # Why this lives here
//
// Until notify-service, this file had no owner. Its WRITER was a shell snippet
// inside a Claude command file (duration parsing, epoch arithmetic, atomic
// replace); its READER was bin/notify.sh; and this package — which defines the
// `muted` history outcome — knew nothing about the file at all. Nothing tested
// the writer. Any second caller (the pi harness, the service) had to
// reimplement epoch semantics against an undocumented format, and drift between
// the two implementations would have been silent.
//
// So the format is defined once, here, and every surface (CLI, HTTP, harness
// command files) is a thin adapter over it.
//
// # On-disk contract
//
//	<state dir>/mute   a single line holding the expiry as Unix epoch seconds
//
// Absent file means not muted. A file whose contents do not parse as an integer
// is treated as expired rather than as an error: it is stale state, and the
// fail-soft contract says an unreadable switch must not silence — or block —
// a notification. Reading an expired or malformed file CLEANS it up, which is
// why the read path takes a writable directory.
const muteFile = "mute"

// MutePath names the mute file inside dir, mirroring VoicesPath/HistoryPath.
func MutePath(dir string) string { return filepath.Join(dir, muteFile) }

// ParseMuteDuration converts an operator-facing duration ("30s", "5m", "1h",
// "2d") into a time.Duration.
//
// Deliberately NOT time.ParseDuration: that accepts "1h30m" and "500ms" but
// rejects "2d", and the operator-facing vocabulary here has always been exactly
// one integer plus one of s/m/h/d. Accepting a superset would let `/notify mute
// 500ms` through as a no-op that looks like it worked.
func ParseMuteDuration(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("notify: empty mute duration (want an integer followed by s, m, h, or d)")
	}
	unit := s[len(s)-1]
	var mult time.Duration
	switch unit {
	case 's':
		mult = time.Second
	case 'm':
		mult = time.Minute
	case 'h':
		mult = time.Hour
	case 'd':
		mult = 24 * time.Hour
	default:
		return 0, fmt.Errorf("notify: mute duration %q must end in s, m, h, or d", s)
	}
	amount, err := strconv.Atoi(s[:len(s)-1])
	if err != nil {
		return 0, fmt.Errorf("notify: mute duration %q must be an integer followed by %c", s, unit)
	}
	if amount <= 0 {
		return 0, fmt.Errorf("notify: mute duration %q must be positive", s)
	}
	return time.Duration(amount) * mult, nil
}

// SetMute mutes until now+d and returns the expiry instant.
//
// Written via same-directory temp file + rename, the same atomic-replace
// discipline WriteVoices uses: a caller killed mid-write must never leave a
// half-written expiry that the reader would parse as some other time.
func SetMute(dir string, d time.Duration) (time.Time, error) {
	if d <= 0 {
		return time.Time{}, fmt.Errorf("notify: mute duration must be positive, got %s", d)
	}
	until := time.Now().Add(d)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return time.Time{}, fmt.Errorf("notify: mkdir %s: %w", dir, err)
	}
	f, err := os.CreateTemp(dir, ".mute.*")
	if err != nil {
		return time.Time{}, fmt.Errorf("notify: create temporary mute file: %w", err)
	}
	tmp := f.Name()
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(tmp)
		}
	}()
	if err := f.Chmod(0o600); err != nil {
		_ = f.Close()
		return time.Time{}, fmt.Errorf("notify: chmod temporary mute file: %w", err)
	}
	if _, err := fmt.Fprintf(f, "%d\n", until.Unix()); err != nil {
		_ = f.Close()
		return time.Time{}, fmt.Errorf("notify: write temporary mute file: %w", err)
	}
	if err := f.Close(); err != nil {
		return time.Time{}, fmt.Errorf("notify: close temporary mute file: %w", err)
	}
	if err := os.Rename(tmp, MutePath(dir)); err != nil {
		return time.Time{}, fmt.Errorf("notify: replace mute file: %w", err)
	}
	committed = true
	return until, nil
}

// ClearMute unmutes. A missing file is success, not an error — "unmute when not
// muted" is a no-op the operator is allowed to perform.
func ClearMute(dir string) error {
	if err := os.Remove(MutePath(dir)); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("notify: remove mute file: %w", err)
	}
	return nil
}

// MuteState reports whether notifications are currently muted and until when.
//
// Expired and malformed files are stale state: they are REMOVED and reported as
// not-muted, so a bad write can never wedge the notifier permanently silent.
// This matches what bin/notify.sh has always done on the read side; it now
// happens in exactly one place.
func MuteState(dir string) (muted bool, until time.Time, err error) {
	b, readErr := os.ReadFile(MutePath(dir))
	if readErr != nil {
		if os.IsNotExist(readErr) {
			return false, time.Time{}, nil
		}
		return false, time.Time{}, fmt.Errorf("notify: read mute file: %w", readErr)
	}
	line := strings.TrimSpace(string(b))
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = strings.TrimSpace(line[:i])
	}
	epoch, convErr := strconv.ParseInt(line, 10, 64)
	if convErr != nil {
		_ = os.Remove(MutePath(dir))
		return false, time.Time{}, nil
	}
	expiry := time.Unix(epoch, 0)
	if !time.Now().Before(expiry) {
		_ = os.Remove(MutePath(dir))
		return false, time.Time{}, nil
	}
	return true, expiry, nil
}
