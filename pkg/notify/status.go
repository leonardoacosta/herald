package notify

import (
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"time"
)

// Status is the operator-facing readout: is Herald wired up, and is it muted.
//
// # Why this lives here rather than in a command file
//
// Status and history readout used to be shell snippets inside the Claude
// `/notify` command file, which meant no non-Claude caller could reach them
// without reimplementing Herald's on-disk layout. Defining the shape once here
// makes every surface — CLI, HTTP, harness command file — a thin adapter, which
// is the whole premise of notify-service.
//
// Every field is safe to emit: paths and a service URL, never a credential.
type Status struct {
	// Version identifies the binary answering. A client that talks to a
	// long-running service needs a way to notice it is speaking to an older
	// build than it expects; without this, skew is invisible until behaviour
	// diverges.
	Version string `json:"version"`

	StateDir  string `json:"state_dir"`
	KokoroURL string `json:"kokoro_url,omitempty"`

	// Muted plus the expiry, so a caller can render "muted for another 12m"
	// without re-deriving it from the file.
	Muted      bool       `json:"muted"`
	MutedUntil *time.Time `json:"muted_until,omitempty"`

	// HistoryCount is cheap reassurance that the pipe has ever run; a zero here
	// on a host that should be chatty is itself a finding.
	HistoryCount int `json:"history_count"`

	// DefaultVoice is the voice an unconfigured project resolves to.
	DefaultVoice string `json:"default_voice"`
}

// Version reports the build identity of this binary.
//
// Read from the Go build info rather than stamped by a linker flag: `go build`
// with no extra flags is how this repo builds, and a version that only appears
// under a release pipeline would read "unknown" in exactly the local case that
// matters. Falls back to "devel" when build info is unavailable (e.g. a test
// binary).
func Version() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "devel"
	}
	var rev, dirty string
	for _, s := range info.Settings {
		switch s.Key {
		case "vcs.revision":
			if len(s.Value) >= 7 {
				rev = s.Value[:7]
			} else {
				rev = s.Value
			}
		case "vcs.modified":
			if s.Value == "true" {
				dirty = "-dirty"
			}
		}
	}
	if rev == "" {
		return "devel"
	}
	return rev + dirty
}

// ReadStatus assembles the readout from dir.
//
// A missing or unreadable piece degrades to its zero value rather than failing
// the whole call: `status` is the command an operator runs when something is
// already wrong, so it must answer even on a half-broken host. The one error it
// does propagate is a voices.json that exists but does not parse — that is a
// typo the operator needs told about, matching ReadVoices' own contract.
func ReadStatus(dir string) (Status, error) {
	st := Status{
		Version:   Version(),
		StateDir:  dir,
		KokoroURL: ResolveBaseURL(),
	}

	muted, until, err := MuteState(dir)
	if err == nil {
		st.Muted = muted
		if muted {
			u := until
			st.MutedUntil = &u
		}
	}

	if records, err := ReadHistory(dir); err == nil {
		st.HistoryCount = len(records)
	}

	voices, err := ReadVoices(dir)
	if err != nil {
		return st, err
	}
	// The EFFECTIVE default, not the raw stored field. An unconfigured
	// voices.json stores "" on purpose — ParseQualified resolves that to the
	// built-in default — so reporting the stored value shows a blank on exactly
	// the fresh host where the operator most needs to know what will be spoken.
	st.DefaultVoice = ParseQualified(voices.Default).String()
	return st, nil
}

// TailHistory returns the most recent n records, newest last — the order
// ReadHistory already produces and the order an operator reads a log in.
//
// n <= 0 returns everything, matching `tail -n` having no "zero" meaning here.
func TailHistory(dir string, n int) ([]Record, error) {
	records, err := ReadHistory(dir)
	if err != nil {
		return nil, err
	}
	if n <= 0 || n >= len(records) {
		return records, nil
	}
	return records[len(records)-n:], nil
}

// ResolveHeraldRoot expands $HERALD the way every shell caller does, so a Go
// surface and a shell surface agree on where the pipe lives. Empty when unset.
func ResolveHeraldRoot() string {
	root := strings.TrimSpace(os.Getenv("HERALD"))
	if root == "" {
		return ""
	}
	if strings.HasPrefix(root, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, root[2:])
		}
	}
	return root
}
