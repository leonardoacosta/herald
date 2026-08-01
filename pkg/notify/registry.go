package notify

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

const (
	HeraldProjectsEnv = "HERALD_PROJECTS_TOML"
	LegacyProjectsEnv = "SHEPHERD_PROJECTS_TOML"
)

type projectRegistry struct {
	Projects []struct {
		Code string `toml:"code"`
		Path string `toml:"path"`
	} `toml:"projects"`
}

// ResolveProjectsPath mirrors bin/lib.sh's project-registry precedence.
func ResolveProjectsPath() string {
	if path := strings.TrimSpace(os.Getenv(HeraldProjectsEnv)); path != "" {
		return path
	}
	if path := strings.TrimSpace(os.Getenv(LegacyProjectsEnv)); path != "" {
		return path
	}
	if dotfiles := strings.TrimSpace(os.Getenv("DOTFILES")); dotfiles != "" {
		return filepath.Join(dotfiles, "home", "projects.toml")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, "dev", "personal", "installfest", "home", "projects.toml")
}

// ReadProjectCodes reads canonical project codes without filtering out entries
// whose repositories are absent on this machine.
func ReadProjectCodes(path string) ([]string, error) {
	var registry projectRegistry
	if _, err := toml.DecodeFile(path, &registry); err != nil {
		return nil, fmt.Errorf("notify: read project registry %s: %w", path, err)
	}
	codes := make([]string, 0, len(registry.Projects))
	seen := make(map[string]struct{}, len(registry.Projects))
	for i, project := range registry.Projects {
		code := strings.TrimSpace(project.Code)
		if code == "" {
			return nil, fmt.Errorf("notify: project registry entry %d has no code", i+1)
		}
		if strings.TrimSpace(project.Path) == "" {
			return nil, fmt.Errorf("notify: project registry entry %q has no path", code)
		}
		if _, exists := seen[code]; exists {
			return nil, fmt.Errorf("notify: project registry contains duplicate code %q", code)
		}
		seen[code] = struct{}{}
		codes = append(codes, code)
	}
	return codes, nil
}

// CanonicalProjectCodes reads the registry selected by ResolveProjectsPath.
func CanonicalProjectCodes() ([]string, error) {
	return ReadProjectCodes(ResolveProjectsPath())
}
