package notify

import "strings"

// Providers this pipe understands as the prefix of a qualified voice.
//
// Mirrors NexusShared's ttsVoiceProviders (TTSObserver.swift) so a voices.json
// row stays meaningful either side of the nexus-agent retirement — the strings
// on disk are the same strings the outgoing system used.
const (
	ProviderKokoro = "kokoro"
	// ProviderLegacy is what a BARE, unqualified voice string means. Before
	// voices were provider-qualified every value was an ElevenLabs voice id,
	// so an unqualified value is an ElevenLabs value by definition — reading
	// it as kokoro would silently hand a UUID to a synthesizer that has no
	// such voice. Same backward-compat rule as
	// TTSObserver.parseQualifiedVoice.
	ProviderLegacy = "elevenlabs"
)

// DefaultVoice is the built-in fallback used when voices.json is absent or
// carries no default. Matches KokoroClient's own default voice.
const DefaultVoice = ProviderKokoro + ":af_heart"

// Voice is a parsed provider-qualified voice.
type Voice struct {
	Provider string
	Voice    string
}

// String re-renders the qualified form, so a resolved Voice can be written
// straight into a history record.
func (v Voice) String() string { return v.Provider + ":" + v.Voice }

// DefaultVoices is the configuration used when voices.json does not exist:
// the built-in default voice and no per-project overrides.
func DefaultVoices() Voices {
	return Voices{Default: DefaultVoice, Projects: map[string]string{}}
}

// ParseQualified splits a voices.json value into provider and voice.
//
// Splits on the FIRST colon only, so a voice id may itself contain a colon
// without ambiguity. A value with no colon is the pre-qualification bare
// format and resolves to ProviderLegacy. An empty value resolves to the
// built-in default rather than to an empty provider — a blank line in
// hand-edited JSON must not produce an unroutable voice.
//
// Mirrors TTSObserver.parseQualifiedVoice (NexusShared).
func ParseQualified(id string) Voice {
	if strings.TrimSpace(id) == "" {
		id = DefaultVoice
	}
	provider, voice, found := strings.Cut(id, ":")
	if !found {
		return Voice{Provider: ProviderLegacy, Voice: id}
	}
	return Voice{Provider: provider, Voice: voice}
}

// Resolve returns the voice for a project code.
//
// Precedence, exactly three paths (task 1.2):
//
//  1. the project's own entry in voices.json
//  2. the configured default, for an unknown or empty project code
//  3. DefaultVoice, when the configuration carries no default either
//
// Whatever value wins is then parsed by ParseQualified, so a bare unqualified
// entry resolves to the legacy provider at every one of those paths rather
// than only at the top one.
func (v Voices) Resolve(project string) Voice {
	if project != "" {
		if id, ok := v.Projects[project]; ok && strings.TrimSpace(id) != "" {
			return ParseQualified(id)
		}
	}
	if strings.TrimSpace(v.Default) != "" {
		return ParseQualified(v.Default)
	}
	return ParseQualified(DefaultVoice)
}

// ResolveVoice reads voices.json from dir and resolves project against it.
//
// The convenience wrapper the pipe actually calls. A read error is returned
// rather than swallowed: bin/notify.sh owns the fail-soft decision (exit 0 with
// a history record), and this package must not pre-empt it by quietly
// substituting a default for a config the operator got wrong.
func ResolveVoice(dir, project string) (Voice, error) {
	voices, err := ReadVoices(dir)
	if err != nil {
		return Voice{}, err
	}
	return voices.Resolve(project), nil
}
