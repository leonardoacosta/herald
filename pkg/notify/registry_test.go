package notify

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeRegistryFixture(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "projects.toml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestReadProjectCodes(t *testing.T) {
	path := writeRegistryFixture(t, `
[[projects]]
code = "hs"
path = "dev/personal/herdr-shepherd"

[[projects]]
code = "cc"
path = ".claude"
`)
	got, err := ReadProjectCodes(path)
	if err != nil {
		t.Fatalf("ReadProjectCodes: %v", err)
	}
	if len(got) != 2 || got[0] != "hs" || got[1] != "cc" {
		t.Fatalf("codes = %v, want [hs cc]", got)
	}
}

func TestReadProjectCodesRejectsDuplicateAndMissingPath(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
		want string
	}{
		{
			name: "duplicate code",
			body: `[[projects]]
code = "hs"
path = "one"
[[projects]]
code = "hs"
path = "two"
`,
			want: "duplicate",
		},
		{
			name: "missing path",
			body: `[[projects]]
code = "hs"
`,
			want: "path",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ReadProjectCodes(writeRegistryFixture(t, tc.body))
			if err == nil || !strings.Contains(strings.ToLower(err.Error()), tc.want) {
				t.Fatalf("ReadProjectCodes error = %v, want %q", err, tc.want)
			}
		})
	}
}

func TestReadProjectCodesReportsUnavailableRegistry(t *testing.T) {
	if _, err := ReadProjectCodes(filepath.Join(t.TempDir(), "missing.toml")); err == nil {
		t.Fatal("ReadProjectCodes accepted an unavailable registry")
	}
}

func TestResolveProjectsPathMatchesShellPrecedence(t *testing.T) {
	t.Setenv(HeraldProjectsEnv, "/primary/projects.toml")
	t.Setenv(LegacyProjectsEnv, "/legacy/projects.toml")
	t.Setenv("DOTFILES", "/dotfiles")
	if got := ResolveProjectsPath(); got != "/primary/projects.toml" {
		t.Fatalf("primary path = %q", got)
	}
	t.Setenv(HeraldProjectsEnv, "")
	if got := ResolveProjectsPath(); got != "/legacy/projects.toml" {
		t.Fatalf("legacy path = %q", got)
	}
	t.Setenv(LegacyProjectsEnv, "")
	if got := ResolveProjectsPath(); got != "/dotfiles/home/projects.toml" {
		t.Fatalf("dotfiles path = %q", got)
	}
}
