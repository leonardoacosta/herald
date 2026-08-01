package notify

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEffectiveVoiceProjectOverride(t *testing.T) {
	cases := []struct {
		name      string
		stored    string
		effective string
	}{
		{name: "qualified", stored: "kokoro:af_bella", effective: "kokoro:af_bella"},
		{name: "legacy bare", stored: "21m00Tcm4TlvDq8ikWAM", effective: "elevenlabs:21m00Tcm4TlvDq8ikWAM"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			voices := Voices{
				Default:  "kokoro:af_heart",
				Projects: map[string]string{"hs": tc.stored},
			}
			got := voices.Effective("hs")
			if got.Project != "hs" || got.Stored != tc.stored || got.Effective != tc.effective || got.Source != VoiceSourceProject {
				t.Fatalf("Effective(hs) = %+v, want stored=%q effective=%q source=%q", got, tc.stored, tc.effective, VoiceSourceProject)
			}
		})
	}
}

func TestEffectiveVoiceInheritedDefault(t *testing.T) {
	voices := Voices{
		Default: "kokoro:af_heart",
		Projects: map[string]string{
			"blank": "  ",
		},
	}
	for _, project := range []string{"unknown", "", "blank"} {
		t.Run(project, func(t *testing.T) {
			got := voices.Effective(project)
			if got.Project != project || got.Stored != "" || got.Effective != "kokoro:af_heart" || got.Source != VoiceSourceDefault {
				t.Fatalf("Effective(%q) = %+v, want inherited kokoro default", project, got)
			}
		})
	}
}

func TestEffectiveVoiceBuiltinFallback(t *testing.T) {
	voices := Voices{Projects: map[string]string{"blank": ""}}
	got := voices.Effective("blank")
	if got.Project != "blank" || got.Stored != "" || got.Effective != DefaultVoice || got.Source != VoiceSourceBuiltin {
		t.Fatalf("Effective(blank) = %+v, want builtin fallback %q", got, DefaultVoice)
	}
}

// The three paths task 1.2 names, one subtest each.
func TestResolveThreePaths(t *testing.T) {
	voices := Voices{
		Default: "kokoro:af_heart",
		Projects: map[string]string{
			"hs": "kokoro:af_bella",
			// Bare, unqualified — the pre-qualification format still on disk
			// for projects configured before voices were provider-qualified.
			"cc": "21m00Tcm4TlvDq8ikWAM",
		},
	}

	t.Run("configured project resolves to its own voice", func(t *testing.T) {
		got := voices.Resolve("hs")
		if got.Provider != ProviderKokoro || got.Voice != "af_bella" {
			t.Errorf("Resolve(hs) = %+v, want kokoro/af_bella", got)
		}
	})

	t.Run("unknown project falls back to the configured default", func(t *testing.T) {
		got := voices.Resolve("no-such-project")
		if got.String() != "kokoro:af_heart" {
			t.Errorf("Resolve(unknown) = %q, want the configured default", got)
		}
	})

	t.Run("bare unqualified voice resolves to the legacy provider", func(t *testing.T) {
		got := voices.Resolve("cc")
		if got.Provider != ProviderLegacy {
			t.Errorf("Resolve(cc).Provider = %q, want %q", got.Provider, ProviderLegacy)
		}
		if got.Voice != "21m00Tcm4TlvDq8ikWAM" {
			t.Errorf("Resolve(cc).Voice = %q, want the bare id unchanged", got.Voice)
		}
	})
}

func TestParseQualified(t *testing.T) {
	cases := []struct {
		in           string
		wantProvider string
		wantVoice    string
	}{
		{"kokoro:af_heart", ProviderKokoro, "af_heart"},
		{"elevenlabs:abc123", ProviderLegacy, "abc123"},
		// No colon: the bare pre-qualification format.
		{"abc123", ProviderLegacy, "abc123"},
		// First colon only — a voice id may carry its own.
		{"kokoro:af_heart:v2", ProviderKokoro, "af_heart:v2"},
		// Empty resolves to the built-in default, never to an empty provider.
		{"", ProviderKokoro, "af_heart"},
		{"   ", ProviderKokoro, "af_heart"},
	}
	for _, c := range cases {
		got := ParseQualified(c.in)
		if got.Provider != c.wantProvider || got.Voice != c.wantVoice {
			t.Errorf("ParseQualified(%q) = %+v, want %s/%s",
				c.in, got, c.wantProvider, c.wantVoice)
		}
	}
}

// An empty project code is the "no project supplied" call, not a lookup miss —
// it takes the default without probing Projects for an "" key.
func TestResolveEmptyProjectTakesDefault(t *testing.T) {
	voices := Voices{Default: "kokoro:am_michael", Projects: map[string]string{"": "kokoro:af_sky"}}
	if got := voices.Resolve(""); got.String() != "kokoro:am_michael" {
		t.Errorf("Resolve(\"\") = %q, want the default", got)
	}
}

// A configuration with no default at all still resolves — the built-in wins
// rather than the pipe going silent.
func TestResolveWithNoConfiguredDefault(t *testing.T) {
	if got := (Voices{}).Resolve("anything"); got.String() != DefaultVoice {
		t.Errorf("Resolve on empty Voices = %q, want %q", got, DefaultVoice)
	}
}

// A blank per-project entry is treated as unconfigured, not as a voice.
func TestResolveBlankProjectEntryFallsBack(t *testing.T) {
	voices := Voices{Default: "kokoro:af_heart", Projects: map[string]string{"hs": "  "}}
	if got := voices.Resolve("hs"); got.String() != "kokoro:af_heart" {
		t.Errorf("Resolve(hs) with a blank entry = %q, want the default", got)
	}
}

func TestReadVoicesMissingFileIsDefault(t *testing.T) {
	dir := t.TempDir()
	got, err := ReadVoices(dir)
	if err != nil {
		t.Fatalf("ReadVoices on a fresh dir: %v", err)
	}
	if got.Default != "" {
		t.Errorf("Default = %q, want an absent configured default", got.Default)
	}
	if got.Resolve("hs").String() != DefaultVoice {
		t.Errorf("an unconfigured host must still resolve a voice")
	}
	if effective := got.Effective("hs"); effective.Source != VoiceSourceBuiltin || effective.Effective != DefaultVoice {
		t.Errorf("missing configuration effective voice = %+v, want builtin fallback", effective)
	}
}

// Malformed hand-edited JSON must surface, not silently degrade to the default
// — that is the difference between "not configured yet" and "you typo'd it".
func TestReadVoicesMalformedIsAnError(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, voicesFile), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadVoices(dir); err == nil {
		t.Fatal("ReadVoices accepted malformed JSON, want an error")
	}
}

func TestReadVoicesSupportsSpeedEntriesAndBlend(t *testing.T) {
	dir := t.TempDir()
	raw := `{
  "default": {"voice": "kokoro:af_heart", "speed": 0.9},
  "projects": {
    "hs": {"voice": "kokoro:af_heart+af_bella(2)", "speed": 0.95},
    "cc": "legacy-id"
  }
}
`
	if err := os.WriteFile(VoicesPath(dir), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	voices, err := ReadVoices(dir)
	if err != nil {
		t.Fatalf("ReadVoices: %v", err)
	}
	project := voices.Resolve("hs")
	if project.String() != "kokoro:af_heart+af_bella(2)" || project.Speed != 0.95 {
		t.Fatalf("project resolution = %+v, want blend at 0.95", project)
	}
	fallback := voices.Resolve("unknown")
	if fallback.String() != DefaultVoice || fallback.Speed != 0.9 {
		t.Fatalf("default resolution = %+v, want af_heart at 0.9", fallback)
	}
	legacy := voices.Resolve("cc")
	if legacy.Provider != ProviderLegacy || legacy.Speed != 0 {
		t.Fatalf("legacy resolution = %+v, want unchanged zero-speed legacy voice", legacy)
	}
	effective := voices.Effective("hs")
	if effective.Speed != 0.95 {
		t.Fatalf("effective read model = %+v, want speed 0.95", effective)
	}
}

func TestLegacyVoicesJSONRemainsScalarAndZeroSpeed(t *testing.T) {
	dir := t.TempDir()
	raw := "{\n  \"default\": \"kokoro:af_heart\",\n  \"projects\": {\n    \"hs\": \"kokoro:af_bella\"\n  }\n}\n"
	if err := os.WriteFile(VoicesPath(dir), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	voices, err := ReadVoices(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := voices.Resolve("hs"); got.String() != "kokoro:af_bella" || got.Speed != 0 {
		t.Fatalf("legacy project resolution = %+v", got)
	}
	if err := WriteVoices(dir, voices); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(VoicesPath(dir))
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != raw {
		t.Fatalf("legacy JSON changed shape:\n%s", after)
	}
}

func TestSetProjectVoicePersistsSpeed(t *testing.T) {
	dir := t.TempDir()
	voices := DefaultVoices()
	voice := ParseQualified("kokoro:af_bella")
	voice.Speed = 0.9
	if err := voices.SetProjectVoice("hs", voice); err != nil {
		t.Fatal(err)
	}
	if err := WriteVoices(dir, voices); err != nil {
		t.Fatal(err)
	}
	reread, err := ReadVoices(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := reread.Resolve("hs"); got.String() != "kokoro:af_bella" || got.Speed != 0.9 {
		t.Fatalf("persisted voice = %+v, want speed 0.9", got)
	}
}

func TestWriteReadVoicesRoundTrip(t *testing.T) {
	dir := t.TempDir()
	want := Voices{Default: "kokoro:af_heart", Projects: map[string]string{"hs": "kokoro:af_bella"}}
	if err := WriteVoices(dir, want); err != nil {
		t.Fatalf("WriteVoices: %v", err)
	}
	got, err := ReadVoices(dir)
	if err != nil {
		t.Fatalf("ReadVoices: %v", err)
	}
	if got.Default != want.Default || got.Projects["hs"] != want.Projects["hs"] {
		t.Errorf("round-trip mismatch: %+v", got)
	}
}

func TestResolveVoiceReadsFromDisk(t *testing.T) {
	dir := t.TempDir()
	if err := WriteVoices(dir, Voices{Default: "kokoro:af_heart",
		Projects: map[string]string{"hs": "kokoro:af_bella"}}); err != nil {
		t.Fatal(err)
	}
	got, err := ResolveVoice(dir, "hs")
	if err != nil {
		t.Fatalf("ResolveVoice: %v", err)
	}
	if got.String() != "kokoro:af_bella" {
		t.Errorf("ResolveVoice(hs) = %q, want kokoro:af_bella", got)
	}
}

// The Herald-specific override wins outright; otherwise state uses the
// documented ~/.local/state/herald default.
func TestResolveStateDir(t *testing.T) {
	t.Setenv(StateDirEnv, "/tmp/explicit-notify")
	if got := ResolveStateDir(); got != "/tmp/explicit-notify" {
		t.Errorf("ResolveStateDir = %q, want the override", got)
	}

	t.Setenv(StateDirEnv, "")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	want := filepath.Join(home, ".local", "state", "herald")
	if got := ResolveStateDir(); got != want {
		t.Errorf("ResolveStateDir = %q, want %q", got, want)
	}
}
