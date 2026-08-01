// Command herald exposes Herald's operator-attention services.
package main

import (
	"fmt"
	"os"

	"github.com/leonardoacosta/herald/pkg/notify"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: herald notify <synth|record|voices|catalog|set|reset|audition> ...")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "notify":
		os.Exit(notify.RunCLI(os.Args[2:]))
	default:
		fmt.Fprintf(os.Stderr, "herald: unknown subcommand %q\n", os.Args[1])
		os.Exit(1)
	}
}
