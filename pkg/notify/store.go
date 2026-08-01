// Package notify owns the state behind Herald's TTS notify pipe: the
// per-project voice configuration and the append-only delivery history.
//
// Herald is the sole owner of this state, synthesis, and delivery contract.
//
// # On-disk contract
//
// Two files live under one Herald state directory:
//
//	voices.json    project code -> provider-qualified voice, plus the default
//	               used for an unconfigured project. Hand-edited by the
//	               operator; this package only reads it, so per-project voice
//	               configuration never requires touching Go source.
//	notify.ndjson  append-only delivery history, one JSON object per line,
//	               newest last. One record per notify call, written whether or
//	               not the call succeeded.
//
// NDJSON for the history rather than a JSON array for the same reason
// bin/lib.sh gives for events.ndjson: a firing notify appends one short line
// under O_APPEND, where a read-modify-write of a growing array would have to
// hold the whole file to add a row — and the history only grows.
//
// # State-dir resolution
//
// HERALD_STATE_DIR overrides the documented default at
// ~/.local/state/herald. The resolver performs no I/O.
package notify

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
	"unicode/utf8"
)

// State file names within the resolved state dir.
const (
	voicesFile  = "voices.json"
	historyFile = "notify.ndjson"
	StateDirEnv = "HERALD_STATE_DIR"
)

// Delivery outcomes. This is a CLOSED set — the notify board renders each one
// as a distinct operator-facing state, so a fifth spelling invented at a call
// site would render as an unknown row rather than a new column.
//
// The transport split is the load-bearing part. A refused connection and a
// timeout are the same "it didn't play" to the caller but completely different
// to an operator: OutcomeTransportTimeout is specifically ssh exiting 124 under
// timeout(1), which means the playback host was asleep or off the tailnet, and
// that is the state worth seeing on the board.
const (
	OutcomeDelivered        = "delivered"
	OutcomeMuted            = "muted"
	OutcomeSynthFailed      = "synth_failed"
	OutcomeTransportFailed  = "transport_failed"
	OutcomeTransportTimeout = "transport_timeout"
)

// MaxRecordedText caps the text carried in a history record, in runes.
//
// The history is a debugging surface, not a transcript. A one-line notify call
// was always well inside this; an on-demand briefing (60-150 words, ~1KB of
// prose) is not, and its full body tells an operator nothing its opening
// sentence does not while making every `notify history` row unreadable.
// Capping here rather than at the briefing call site means the invariant holds
// for every writer that reaches the store, present and future.
//
// The SPOKEN text is untouched — synthesis has already happened by the time a
// record is appended, so this only ever shortens the recorded copy.
const MaxRecordedText = 300

// truncateRecordedText shortens s to MaxRecordedText runes, the last of which
// is an ellipsis marking the cut. Rune-based rather than byte-based so a cut
// landing mid-character cannot emit invalid UTF-8 into the NDJSON.
func truncateRecordedText(s string) string {
	if utf8.RuneCountInString(s) <= MaxRecordedText {
		return s
	}
	return string([]rune(s)[:MaxRecordedText-1]) + "…"
}

// ValidOutcome reports whether s is one of the five sanctioned outcomes.
// AppendRecord rejects anything else rather than writing a row the board
// cannot render.
func ValidOutcome(s string) bool {
	switch s {
	case OutcomeDelivered, OutcomeMuted, OutcomeSynthFailed, OutcomeTransportFailed, OutcomeTransportTimeout:
		return true
	}
	return false
}

// Voices is the parsed voices.json.
//
// Values on both sides are provider-qualified ("kokoro:af_heart"), matching the
// wire vocabulary NexusShared already uses. A bare unqualified value is still
// accepted and resolves to the legacy provider — see ParseQualified.
type Voices struct {
	// Default is the voice for a project with no entry in Projects, and for
	// a call carrying no project at all.
	Default string `json:"default"`
	// Projects maps a projects.toml project code ("hs", "cc") to its voice.
	Projects map[string]string `json:"projects"`
	// Speeds are kept alongside the string fields in Go. Custom JSON methods
	// preserve legacy scalar entries and emit an object only when speed is set.
	DefaultSpeed  float64            `json:"-"`
	ProjectSpeeds map[string]float64 `json:"-"`
}

type voiceEntryWire struct {
	Voice string  `json:"voice"`
	Speed float64 `json:"speed,omitempty"`
}

type voicesWire struct {
	Default  json.RawMessage            `json:"default"`
	Projects map[string]json.RawMessage `json:"projects"`
}

func decodeVoiceEntry(raw json.RawMessage) (voiceEntryWire, error) {
	var scalar string
	if err := json.Unmarshal(raw, &scalar); err == nil {
		return voiceEntryWire{Voice: scalar}, nil
	}
	var entry voiceEntryWire
	if err := json.Unmarshal(raw, &entry); err != nil {
		return voiceEntryWire{}, err
	}
	return entry, nil
}

// UnmarshalJSON accepts both the legacy string entry and the speed-aware object
// form, per default and per project.
func (v *Voices) UnmarshalJSON(data []byte) error {
	var wire voicesWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	v.Default = ""
	v.DefaultSpeed = 0
	v.Projects = map[string]string{}
	v.ProjectSpeeds = map[string]float64{}
	if len(wire.Default) > 0 && string(wire.Default) != "null" {
		entry, err := decodeVoiceEntry(wire.Default)
		if err != nil {
			return fmt.Errorf("decode default voice entry: %w", err)
		}
		v.Default, v.DefaultSpeed = entry.Voice, entry.Speed
	}
	for project, raw := range wire.Projects {
		entry, err := decodeVoiceEntry(raw)
		if err != nil {
			return fmt.Errorf("decode project %q voice entry: %w", project, err)
		}
		v.Projects[project] = entry.Voice
		if entry.Speed != 0 {
			v.ProjectSpeeds[project] = entry.Speed
		}
	}
	return nil
}

// MarshalJSON emits the old scalar form when speed is zero and the object form
// only for configured prosody.
func (v Voices) MarshalJSON() ([]byte, error) {
	defaultValue := any(v.Default)
	if v.DefaultSpeed != 0 {
		defaultValue = voiceEntryWire{Voice: v.Default, Speed: v.DefaultSpeed}
	}
	projects := make(map[string]any, len(v.Projects))
	for project, voice := range v.Projects {
		if speed := v.ProjectSpeeds[project]; speed != 0 {
			projects[project] = voiceEntryWire{Voice: voice, Speed: speed}
		} else {
			projects[project] = voice
		}
	}
	return json.Marshal(struct {
		Default  any            `json:"default"`
		Projects map[string]any `json:"projects"`
	}{Default: defaultValue, Projects: projects})
}

// Record is one line of notify.ndjson: one notify call, delivered or not.
//
// Reason is omitempty because a delivered record has nothing to explain;
// every non-delivered outcome is expected to carry one.
type Record struct {
	TS      time.Time `json:"ts"`
	Project string    `json:"project"`
	Text    string    `json:"text"`
	Voice   string    `json:"voice"`
	Speed   float64   `json:"speed,omitempty"`
	Outcome string    `json:"outcome"`
	Reason  string    `json:"reason,omitempty"`
}

// ResolveStateDir returns the directory holding the notify state files:
//
//  1. HERALD_STATE_DIR env var (explicit override, wins outright — also what
//     the tests use, so no test touches the operator's real state)
//  2. ~/.local/state/herald
//
// Pure function: env reads only, no mkdir, no existence checks.
func ResolveStateDir() string {
	if d := os.Getenv(StateDirEnv); d != "" {
		return d
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".local", "state", "herald")
	}
	return filepath.Join(home, ".local", "state", "herald")
}

// VoicesPath and HistoryPath name the two state files inside dir. Taking dir as
// a parameter (rather than each calling ResolveStateDir) is what lets a test
// point the whole package at t.TempDir().
func VoicesPath(dir string) string  { return filepath.Join(dir, voicesFile) }
func HistoryPath(dir string) string { return filepath.Join(dir, historyFile) }

// ReadVoices reads voices.json.
//
// A missing file is NOT an error: it is the un-configured state, and returns
// DefaultVoices(). The pipe must speak on a host where the operator has never
// written a config, so there is no path here that turns "no voices.json" into
// a silent notification.
//
// A file that exists but does not parse IS an error — that is a typo in
// hand-edited JSON, and silently falling back to the default would hide it.
func ReadVoices(dir string) (Voices, error) {
	b, err := os.ReadFile(VoicesPath(dir))
	if err != nil {
		if os.IsNotExist(err) {
			return DefaultVoices(), nil
		}
		return Voices{}, fmt.Errorf("notify: read %s: %w", voicesFile, err)
	}
	var v Voices
	if err := json.Unmarshal(b, &v); err != nil {
		return Voices{}, fmt.Errorf("notify: parse %s: %w", voicesFile, err)
	}
	if v.Projects == nil {
		v.Projects = map[string]string{}
	}
	return v, nil
}

// WriteVoices atomically replaces voices.json with an indented mode-0600 file.
func WriteVoices(dir string, v Voices) error {
	return writeVoicesAtomic(dir, v, os.Rename)
}

func writeVoicesAtomic(dir string, v Voices, rename func(string, string) error) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("notify: mkdir %s: %w", dir, err)
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Errorf("notify: encode %s: %w", voicesFile, err)
	}
	b = append(b, '\n')
	f, err := os.CreateTemp(dir, ".voices.json.*")
	if err != nil {
		return fmt.Errorf("notify: create temporary %s: %w", voicesFile, err)
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
		return fmt.Errorf("notify: chmod temporary %s: %w", voicesFile, err)
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return fmt.Errorf("notify: write temporary %s: %w", voicesFile, err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("notify: sync temporary %s: %w", voicesFile, err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("notify: close temporary %s: %w", voicesFile, err)
	}
	if err := rename(tmp, VoicesPath(dir)); err != nil {
		return fmt.Errorf("notify: replace %s: %w", voicesFile, err)
	}
	committed = true
	return nil
}

// AppendRecord appends exactly one line to notify.ndjson.
//
// O_APPEND rather than a read-modify-write: the history is append-only and must
// never lose earlier entries to a concurrent writer's stale read — two agents
// notifying at once is the normal case, not the edge case. A single write of
// one short line under O_APPEND is atomic on Linux at this size. Same reasoning
// as any append-only operator history.
//
// A zero TS is stamped with time.Now().UTC() so no caller can write an
// undatable row; an unknown outcome is rejected outright; Text over
// MaxRecordedText runes is truncated.
func AppendRecord(dir string, r Record) error {
	if !ValidOutcome(r.Outcome) {
		return fmt.Errorf("notify: outcome %q is not one of %s/%s/%s/%s/%s",
			r.Outcome, OutcomeDelivered, OutcomeMuted, OutcomeSynthFailed,
			OutcomeTransportFailed, OutcomeTransportTimeout)
	}
	if r.TS.IsZero() {
		r.TS = time.Now().UTC()
	}
	r.Text = truncateRecordedText(r.Text)
	line, err := json.Marshal(r)
	if err != nil {
		return fmt.Errorf("notify: encode record: %w", err)
	}
	line = append(line, '\n')

	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("notify: mkdir %s: %w", dir, err)
	}
	f, err := os.OpenFile(HistoryPath(dir), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("notify: open %s: %w", historyFile, err)
	}
	if _, err := f.Write(line); err != nil {
		f.Close()
		return fmt.Errorf("notify: append %s: %w", historyFile, err)
	}
	return f.Close()
}

// ReadHistory reads notify.ndjson oldest-first. A missing file is not an error
// — it is the first-run state, and returns a nil slice, which is what lets the
// notify board render an empty history without special-casing it.
func ReadHistory(dir string) ([]Record, error) {
	f, err := os.Open(HistoryPath(dir))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("notify: open %s: %w", historyFile, err)
	}
	defer f.Close()

	var out []Record
	sc := bufio.NewScanner(f)
	// Notification text is short, but a caller pasting a stack trace into a
	// notify call must not corrupt the read for every later row — raise the
	// 64KB default rather than surfacing a truncated line as a decode error.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	line := 0
	for sc.Scan() {
		line++
		b := bytes.TrimSpace(sc.Bytes())
		if len(b) == 0 {
			continue
		}
		var r Record
		if err := json.Unmarshal(b, &r); err != nil {
			return nil, fmt.Errorf("notify: %s line %d: %w", historyFile, line, err)
		}
		out = append(out, r)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("notify: scan %s: %w", historyFile, err)
	}
	return out, nil
}
