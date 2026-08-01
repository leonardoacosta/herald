package notify

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSetProjectVoiceAddsAndReplacesOnlyTheTarget(t *testing.T) {
	voices := Voices{
		Default: "legacy-default-id",
		Projects: map[string]string{
			"keep":   "legacy-project-id",
			"target": "kokoro:af_heart",
		},
	}
	if err := voices.SetProjectVoice("target", ParseQualified("kokoro:af_bella")); err != nil {
		t.Fatalf("replace target: %v", err)
	}
	if err := voices.SetProjectVoice("new", ParseQualified("kokoro:af_nicole")); err != nil {
		t.Fatalf("add project: %v", err)
	}
	if voices.Default != "legacy-default-id" || voices.Projects["keep"] != "legacy-project-id" {
		t.Fatalf("mutation rewrote legacy or unrelated values: %+v", voices)
	}
	if voices.Projects["target"] != "kokoro:af_bella" || voices.Projects["new"] != "kokoro:af_nicole" {
		t.Fatalf("mutation did not store qualified Kokoro values: %+v", voices.Projects)
	}
}

func TestRemoveProjectVoicePreservesEverythingElse(t *testing.T) {
	voices := Voices{
		Default: "legacy-default-id",
		Projects: map[string]string{
			"keep":   "legacy-project-id",
			"target": "kokoro:af_bella",
		},
	}
	if err := voices.RemoveProjectVoice("target"); err != nil {
		t.Fatalf("RemoveProjectVoice: %v", err)
	}
	if _, exists := voices.Projects["target"]; exists {
		t.Fatal("target mapping still exists after reset")
	}
	if voices.Default != "legacy-default-id" || voices.Projects["keep"] != "legacy-project-id" {
		t.Fatalf("reset rewrote default or unrelated mapping: %+v", voices)
	}
}

func TestProjectVoiceMutationsRejectInvalidInput(t *testing.T) {
	voices := DefaultVoices()
	if err := voices.SetProjectVoice("", ParseQualified(DefaultVoice)); err == nil {
		t.Fatal("SetProjectVoice accepted an empty project code")
	}
	if err := voices.SetProjectVoice("hs", ParseQualified("legacy-id")); err == nil {
		t.Fatal("SetProjectVoice accepted a new legacy voice")
	}
	if err := voices.RemoveProjectVoice(""); err == nil {
		t.Fatal("RemoveProjectVoice accepted an empty project code")
	}
}

func TestWriteVoicesIsAtomicAndMode0600(t *testing.T) {
	dir := t.TempDir()
	prior := Voices{Default: "kokoro:af_heart", Projects: map[string]string{"hs": "legacy-id"}}
	if err := WriteVoices(dir, prior); err != nil {
		t.Fatalf("seed voices: %v", err)
	}
	path := VoicesPath(dir)
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	renameErr := errors.New("injected rename failure")
	err = writeVoicesAtomic(dir, Voices{Default: "kokoro:af_bella"}, func(string, string) error {
		return renameErr
	})
	if !errors.Is(err, renameErr) {
		t.Fatalf("writeVoicesAtomic error = %v, want injected rename failure", err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Fatalf("failed rename changed prior file: before=%q after=%q", before, after)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".voices.json.") {
			t.Fatalf("failed atomic write leaked temp file %q", entry.Name())
		}
	}

	if err := WriteVoices(dir, Voices{Default: "kokoro:af_bella"}); err != nil {
		t.Fatalf("successful atomic write: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("voices mode = %o, want 600", info.Mode().Perm())
	}
}

func TestWriteVoicesCreateFailureDoesNotReplaceAReadableFile(t *testing.T) {
	dir := t.TempDir()
	path := VoicesPath(dir)
	prior := []byte("{\"default\":\"kokoro:af_heart\"}\n")
	if err := os.WriteFile(path, prior, 0o600); err != nil {
		t.Fatal(err)
	}
	blockingParent := filepath.Join(dir, "not-a-directory")
	if err := os.WriteFile(blockingParent, []byte("block"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteVoices(blockingParent, Voices{Default: "kokoro:af_bella"}); err == nil {
		t.Fatal("WriteVoices accepted a state directory that is a file")
	}
	after, err := os.ReadFile(path)
	if err != nil || string(after) != string(prior) {
		t.Fatalf("unrelated readable voices file changed after create failure: data=%q err=%v", after, err)
	}
}
