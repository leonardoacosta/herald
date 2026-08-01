package notify

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

// RunCLI implements `herald notify <subcommand>` and returns the process
// exit code.
//
// # Why this seam exists
//
// bin/notify.sh is the pipe (task 2.2) and this package owns synthesis, voice
// resolution, and the history contract (tasks 1.1-1.3, 2.1). Something has to
// join them. The alternative — re-implementing the kokoro wire contract and the
// voices.json precedence rules in bash with curl and jq — would put the same
// contract in two places, which is exactly what task 2.1's "mirror the wire
// contract rather than re-derive it" forbids. So the shell owns what only the
// shell can do (argument handling, the ssh transport and its timeout(1) bound),
// and shells out to here for everything else.
//
// # Contract with bin/notify.sh
//
//	notify synth --text T [--project P] --out FILE [--timeout SECONDS]
//	  stdout: the resolved provider-qualified voice, one line, ALWAYS — including
//	          on failure, because the history record must carry the voice that
//	          was going to be used even when nothing was synthesized.
//	  stderr: the failure reason, which becomes the record's reason verbatim.
//	  exit:   0 wrote FILE, 1 did not.
//
//	notify record --text T [--project P] --voice V --outcome O [--reason R]
//	  exit:   0 appended, 1 rejected (unknown outcome) or unwritable.
//
// Splitting stdout (the voice) from stderr (the reason) rather than emitting one
// JSON object is deliberate: it keeps bin/notify.sh free of a jq dependency on
// its hot path, and a voice string can never contain a newline, so a single
// stdout line is unambiguous.
func RunCLI(args []string) int {
	return runCLI(args, os.Stdout, os.Stderr)
}

func runCLI(args []string, stdout, stderr io.Writer) int {
	if len(args) < 1 {
		fmt.Fprintln(stderr, "usage: herald notify <synth|record|voices|catalog|set|reset|audition|status|history|mute|unmute> ...")
		return 1
	}
	switch args[0] {
	case "synth":
		return runSynth(args[1:], stdout, stderr)
	case "record":
		return runRecord(args[1:], stderr)
	case "voices":
		return runVoices(args[1:], stdout, stderr)
	case "catalog":
		return runCatalog(args[1:], stdout, stderr)
	case "set":
		return runSetVoice(args[1:], stdout, stderr)
	case "reset":
		return runResetVoice(args[1:], stdout, stderr)
	case "audition":
		return runAudition(args[1:], stdout, stderr)
	case "status":
		return runStatus(args[1:], stdout, stderr)
	case "history":
		return runHistory(args[1:], stdout, stderr)
	case "mute":
		return runMute(args[1:], stdout, stderr)
	case "unmute":
		return runUnmute(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "herald notify: unknown subcommand %q\n", args[0])
		return 1
	}
}

// flagsOf builds a FlagSet that reports errors through w and never calls
// os.Exit, so RunCLI stays testable and every path returns a code.
func flagsOf(name string, w io.Writer) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(w)
	return fs
}

func rejectPositionals(fs *flag.FlagSet, stderr io.Writer) bool {
	if fs.NArg() == 0 {
		return false
	}
	fmt.Fprintf(stderr, "%s: unexpected arguments: %s\n", fs.Name(), strings.Join(fs.Args(), " "))
	return true
}

func configuredClient(timeoutSeconds float64) (*Client, error) {
	return NewClient(ResolveBaseURL(), time.Duration(timeoutSeconds*float64(time.Second)))
}

func canonicalProject(code string) error {
	if strings.TrimSpace(code) == "" {
		return fmt.Errorf("notify: --project is required")
	}
	codes, err := CanonicalProjectCodes()
	if err != nil {
		return err
	}
	for _, candidate := range codes {
		if candidate == code {
			return nil
		}
	}
	return fmt.Errorf("notify: project %q is not present in the canonical registry", code)
}

func runVoices(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify voices", stderr)
	asJSON := fs.Bool("json", false, "emit stable JSON")
	if err := fs.Parse(args); err != nil || rejectPositionals(fs, stderr) {
		return 1
	}
	codes, err := CanonicalProjectCodes()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	voices, err := ReadVoices(ResolveStateDir())
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	rows := make([]EffectiveVoice, 0, len(codes))
	for _, code := range codes {
		rows = append(rows, voices.Effective(code))
	}
	if *asJSON {
		if err := json.NewEncoder(stdout).Encode(rows); err != nil {
			fmt.Fprintf(stderr, "notify voices: encode output: %v\n", err)
			return 1
		}
		return 0
	}
	for _, row := range rows {
		fmt.Fprintf(stdout, "%s\t%s\t%s\t%s\n", row.Project, row.Stored, row.Effective, row.Source)
	}
	return 0
}

func runCatalog(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify catalog", stderr)
	asJSON := fs.Bool("json", false, "emit stable JSON")
	timeout := fs.Float64("timeout", DefaultTimeout.Seconds(), "catalog timeout in seconds")
	if err := fs.Parse(args); err != nil || rejectPositionals(fs, stderr) {
		return 1
	}
	client, err := configuredClient(*timeout)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	voices, err := client.Catalog(context.Background())
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if *asJSON {
		if err := json.NewEncoder(stdout).Encode(voices); err != nil {
			fmt.Fprintf(stderr, "notify catalog: encode output: %v\n", err)
			return 1
		}
		return 0
	}
	for _, voice := range voices {
		fmt.Fprintf(stdout, "%s\t%s\n", voice.ID, voice.Name)
	}
	return 0
}

func runSetVoice(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify set", stderr)
	project := fs.String("project", "", "canonical project code")
	setDefault := fs.Bool("default", false, "set the default voice")
	value := fs.String("voice", "", "provider-qualified Kokoro voice")
	speed := fs.Float64("speed", 0, "speech speed (0 for engine default, or 0.5 through 2.0)")
	timeout := fs.Float64("timeout", DefaultTimeout.Seconds(), "catalog timeout in seconds")
	if err := fs.Parse(args); err != nil || rejectPositionals(fs, stderr) {
		return 1
	}
	hasProject := strings.TrimSpace(*project) != ""
	if *setDefault == hasProject {
		fmt.Fprintln(stderr, "notify set: exactly one of --default or --project is required")
		return 1
	}
	if hasProject {
		if err := canonicalProject(*project); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
	}
	if strings.TrimSpace(*value) == "" {
		fmt.Fprintln(stderr, "notify set: --voice is required")
		return 1
	}
	if *speed != 0 && (*speed < 0.5 || *speed > 2.0) {
		fmt.Fprintln(stderr, "notify set: --speed must be 0 or between 0.5 and 2.0")
		return 1
	}
	voice := ParseQualified(*value)
	voice.Speed = *speed
	client, err := configuredClient(*timeout)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if err := client.ValidateVoice(context.Background(), voice); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	dir := ResolveStateDir()
	voices, err := ReadVoices(dir)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	target := *project
	if *setDefault {
		voices.Default = voice.String()
		voices.DefaultSpeed = voice.Speed
		target = "default"
	} else {
		if err := voices.SetProjectVoice(*project, voice); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
	}
	if err := WriteVoices(dir, voices); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	fmt.Fprintf(stdout, "%s\t%s\n", target, voice.String())
	return 0
}

func runResetVoice(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify reset", stderr)
	project := fs.String("project", "", "canonical project code")
	if err := fs.Parse(args); err != nil || rejectPositionals(fs, stderr) {
		return 1
	}
	if err := canonicalProject(*project); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	dir := ResolveStateDir()
	voices, err := ReadVoices(dir)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if err := voices.RemoveProjectVoice(*project); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if err := WriteVoices(dir, voices); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	fmt.Fprintf(stdout, "%s\t%s\n", *project, voices.Resolve(*project).String())
	return 0
}

func runAudition(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify audition", stderr)
	value := fs.String("voice", "", "provider-qualified Kokoro voice")
	timeout := fs.Float64("timeout", DefaultTimeout.Seconds(), "audition timeout in seconds")
	if err := fs.Parse(args); err != nil || rejectPositionals(fs, stderr) {
		return 1
	}
	if strings.TrimSpace(*value) == "" {
		fmt.Fprintln(stderr, "notify audition: --voice is required")
		return 1
	}
	voice := ParseQualified(*value)
	client, err := configuredClient(*timeout)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if err := client.ValidateVoice(context.Background(), voice); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if err := client.Audition(context.Background(), voice); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	fmt.Fprintln(stdout, voice.String())
	return 0
}

func runSynth(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify synth", stderr)
	project := fs.String("project", "", "project code whose configured voice to use")
	text := fs.String("text", "", "text to speak")
	out := fs.String("out", "", "file to write the audio bytes to")
	speedOut := fs.String("speed-out", "", "optional file to write the effective speed")
	timeout := fs.Float64("timeout", DefaultTimeout.Seconds(), "synthesis timeout in seconds")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *out == "" {
		fmt.Fprintln(stderr, "notify synth: --out is required")
		return 1
	}

	// Resolve the voice FIRST and print it unconditionally. Every later failure
	// path still needs it for the history record, and a voices.json the operator
	// typo'd must not also cost us the ability to say which voice was intended.
	dir := ResolveStateDir()
	voice, err := ResolveVoice(dir, *project)
	if err != nil {
		fmt.Fprintln(stdout, DefaultVoice)
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, voice.String())
	if *speedOut != "" {
		speedText := strconv.FormatFloat(voice.Speed, 'f', -1, 64) + "\n"
		if err := os.WriteFile(*speedOut, []byte(speedText), 0o600); err != nil {
			fmt.Fprintf(stderr, "notify synth: write speed metadata %s: %v\n", *speedOut, err)
			return 1
		}
	}

	client, err := NewClient(ResolveBaseURL(), time.Duration(*timeout*float64(time.Second)))
	if err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}

	audio, err := client.Synthesize(context.Background(), *text, voice)
	if err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}

	// 0o600: the audio is the notification text spoken aloud, and it lands in a
	// world-readable temp dir.
	if err := os.WriteFile(*out, audio, 0o600); err != nil {
		fmt.Fprintf(stderr, "notify synth: write %s: %v\n", *out, err)
		return 1
	}
	return 0
}

func runRecord(args []string, stderr io.Writer) int {
	fs := flagsOf("notify record", stderr)
	project := fs.String("project", "", "project code this notification belongs to")
	text := fs.String("text", "", "the notification text")
	voice := fs.String("voice", "", "the resolved provider-qualified voice (resolved from project when omitted)")
	speed := fs.Float64("speed", 0, "the effective synthesis speed")
	outcome := fs.String("outcome", "", "one of delivered|muted|synth_failed|transport_failed|transport_timeout")
	reason := fs.String("reason", "", "failure reason, for any non-delivered outcome")
	if err := fs.Parse(args); err != nil {
		return 1
	}

	// AppendRecord validates the outcome against the closed set; catching it
	// here first lets the message name the caller's mistake instead of
	// surfacing a store-layer error.
	if !ValidOutcome(*outcome) {
		fmt.Fprintf(stderr, "notify record: --outcome %q is not one of %s|%s|%s|%s|%s\n",
			*outcome, OutcomeDelivered, OutcomeMuted, OutcomeSynthFailed, OutcomeTransportFailed, OutcomeTransportTimeout)
		return 1
	}

	resolvedVoice, resolvedSpeed := *voice, *speed
	if strings.TrimSpace(resolvedVoice) == "" {
		// A muted attempt never synthesizes, but its history should still carry
		// the voice it would have used. If configuration is unreadable, retain
		// the stronger one-attempt/one-record invariant with an explicit marker.
		if effective, err := ResolveVoice(ResolveStateDir(), *project); err == nil {
			resolvedVoice, resolvedSpeed = effective.String(), effective.Speed
		} else {
			resolvedVoice = "unknown"
		}
	}

	err := AppendRecord(ResolveStateDir(), Record{
		Project: *project,
		Text:    *text,
		Voice:   resolvedVoice,
		Speed:   resolvedSpeed,
		Outcome: *outcome,
		// Reasons arrive as captured stderr, which is often multi-line and
		// trailing-newline'd. Collapse it: the board renders one row per
		// record, and encoding/json would otherwise embed literal \n runs.
		Reason: collapseReason(*reason),
	})
	if err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}
	return 0
}

// collapseReason folds captured stderr into a single trimmed line.
func collapseReason(s string) string {
	if s == "" {
		return ""
	}
	return strings.Join(strings.Fields(s), " ")
}

// runStatus emits the operator readout. --json is the stable machine surface
// (same contract as `voices --json`); the default is a human line block.
func runStatus(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify status", stderr)
	asJSON := fs.Bool("json", false, "emit stable JSON")
	if err := fs.Parse(args); err != nil || rejectPositionals(fs, stderr) {
		return 1
	}
	dir := ResolveStateDir()
	st, err := ReadStatus(dir)
	if err != nil {
		// A voices.json typo is worth reporting, but the readout is still
		// printed: status is what you run when something is already broken.
		fmt.Fprintf(stderr, "%v\n", err)
	}
	if *asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		if encErr := enc.Encode(st); encErr != nil {
			fmt.Fprintf(stderr, "notify: encode status: %v\n", encErr)
			return 1
		}
		return 0
	}
	fmt.Fprintf(stdout, "version:       %s\n", st.Version)
	fmt.Fprintf(stdout, "state dir:     %s\n", st.StateDir)
	fmt.Fprintf(stdout, "kokoro:        %s\n", orDash(st.KokoroURL))
	fmt.Fprintf(stdout, "default voice: %s\n", orDash(st.DefaultVoice))
	fmt.Fprintf(stdout, "history:       %d record(s)\n", st.HistoryCount)
	if st.Muted && st.MutedUntil != nil {
		fmt.Fprintf(stdout, "mute:          until %s\n", st.MutedUntil.Format(time.RFC3339))
	} else {
		fmt.Fprintln(stdout, "mute:          off")
	}
	return 0
}

func orDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "-"
	}
	return s
}

// runHistory renders the tail of the delivery history.
func runHistory(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify history", stderr)
	asJSON := fs.Bool("json", false, "emit stable JSON")
	n := fs.Int("n", 10, "how many records to show (0 for all)")
	if err := fs.Parse(args); err != nil || rejectPositionals(fs, stderr) {
		return 1
	}
	records, err := TailHistory(ResolveStateDir(), *n)
	if err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}
	if *asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		// Encode a non-nil slice so an empty history is `[]`, not `null` — a
		// consumer should not have to special-case first-run state.
		if records == nil {
			records = []Record{}
		}
		if encErr := enc.Encode(records); encErr != nil {
			fmt.Fprintf(stderr, "notify: encode history: %v\n", encErr)
			return 1
		}
		return 0
	}
	for _, r := range records {
		fmt.Fprintf(stdout, "%s\t%s\t%s\t%s\t%s\n",
			r.TS.Format(time.RFC3339), r.Outcome, orDash(r.Project), orDash(r.Voice), r.Text)
	}
	return 0
}

// runMute mutes for a duration expressed in the operator vocabulary.
func runMute(args []string, stdout, stderr io.Writer) int {
	// Go's flag package stops parsing at the first positional, so `mute 1h --json`
	// would read --json as an argument rather than a flag. The operator types the
	// duration first, so lift the first non-flag token out and let the parser see
	// only flags.
	spec := "1h"
	flagArgs := make([]string, 0, len(args))
	seenDuration := false
	for _, a := range args {
		if !seenDuration && !strings.HasPrefix(a, "-") {
			spec = a
			seenDuration = true
			continue
		}
		flagArgs = append(flagArgs, a)
	}

	fs := flagsOf("notify mute", stderr)
	asJSON := fs.Bool("json", false, "emit stable JSON")
	if err := fs.Parse(flagArgs); err != nil || rejectPositionals(fs, stderr) {
		return 1
	}
	d, err := ParseMuteDuration(spec)
	if err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}
	until, err := SetMute(ResolveStateDir(), d)
	if err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}
	if *asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(map[string]any{"muted": true, "until": until})
		return 0
	}
	fmt.Fprintf(stdout, "Herald muted until %s.\n", until.Format(time.RFC3339))
	return 0
}

// runUnmute clears the mute. Unmuting when not muted is a no-op, not an error.
func runUnmute(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify unmute", stderr)
	asJSON := fs.Bool("json", false, "emit stable JSON")
	if err := fs.Parse(args); err != nil || rejectPositionals(fs, stderr) {
		return 1
	}
	if err := ClearMute(ResolveStateDir()); err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}
	if *asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(map[string]any{"muted": false})
		return 0
	}
	fmt.Fprintln(stdout, "Herald unmuted.")
	return 0
}
