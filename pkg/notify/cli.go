package notify

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// RunCLI implements `herald notify <synth|record>` and returns the process
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
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: herald notify <synth|record> ...")
		return 1
	}
	switch args[0] {
	case "synth":
		return runSynth(args[1:], os.Stdout, os.Stderr)
	case "record":
		return runRecord(args[1:], os.Stderr)
	default:
		fmt.Fprintf(os.Stderr, "herald notify: unknown subcommand %q\n", args[0])
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

func runSynth(args []string, stdout, stderr io.Writer) int {
	fs := flagsOf("notify synth", stderr)
	project := fs.String("project", "", "project code whose configured voice to use")
	text := fs.String("text", "", "text to speak")
	out := fs.String("out", "", "file to write the audio bytes to")
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
	voice := fs.String("voice", "", "the resolved provider-qualified voice")
	outcome := fs.String("outcome", "", "one of delivered|synth_failed|transport_failed|transport_timeout")
	reason := fs.String("reason", "", "failure reason, for any non-delivered outcome")
	if err := fs.Parse(args); err != nil {
		return 1
	}

	// AppendRecord validates the outcome against the closed set; catching it
	// here first lets the message name the caller's mistake instead of
	// surfacing a store-layer error.
	if !ValidOutcome(*outcome) {
		fmt.Fprintf(stderr, "notify record: --outcome %q is not one of %s|%s|%s|%s\n",
			*outcome, OutcomeDelivered, OutcomeSynthFailed, OutcomeTransportFailed, OutcomeTransportTimeout)
		return 1
	}

	err := AppendRecord(ResolveStateDir(), Record{
		Project: *project,
		Text:    *text,
		Voice:   *voice,
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
