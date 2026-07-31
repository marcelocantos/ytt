// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

// Command ytt fetches YouTube transcripts and drives the bulk ingest pipeline.
package main

import (
	"context"
	"embed"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

// version is overridden at build time via -ldflags "-X main.version=...".
// The release workflow verifies it against the tag.
var version = "0.11.0"

//go:embed agents-guide.md
var embedded embed.FS

// fetch is indirected through a variable so tests can substitute a fetcher and
// exercise the CLI's multi-video, separator and exit-code behaviour without a
// network round trip.
var fetch = Fetch

const usage = `usage: ytt [-h] [-t | -j] [--help-agent] [VIDEO ...]

Fetch YouTube video transcripts from the command line.

VIDEO may be a video ID or any YouTube URL (watch?v=, youtu.be/, /shorts/,
/embed/). Multiple videos may be given.

  -t, --timestamps   prefix each cue with [MM:SS]
  -j, --json         emit the full transcript payload as JSON (JSONL when
                     several videos are given)
      --help-agent   print the agent guide (usage text first)
  -h, --help         show this help

  ytt ingest [--dry-run] [PLAYLIST_URL]
                     bulk-ingest a playlist + tracked channels
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	// `ingest` is a passthrough to the bundled workflow; short-circuit before
	// flag parsing so its own flags reach it untouched.
	if len(args) > 0 && args[0] == "ingest" {
		return runIngest(args[1:], stdout, stderr)
	}

	fs := flag.NewFlagSet("ytt", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() { fmt.Fprint(stderr, usage) }

	var timestamps, asJSON, helpAgent, showVersion bool
	fs.BoolVar(&timestamps, "timestamps", false, "prefix each cue with [MM:SS]")
	fs.BoolVar(&timestamps, "t", false, "prefix each cue with [MM:SS]")
	fs.BoolVar(&asJSON, "json", false, "emit JSON")
	fs.BoolVar(&asJSON, "j", false, "emit JSON")
	fs.BoolVar(&helpAgent, "help-agent", false, "print the agent guide")
	fs.BoolVar(&showVersion, "version", false, "print the version")
	fs.BoolVar(&showVersion, "V", false, "print the version")
	if err := fs.Parse(args); err != nil {
		// The flag package reports -h/--help as ErrHelp. That is a successful
		// request for usage, not a usage error: argparse exited 0 for it, and
		// `ytt --help | less` must not look like a failure.
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprint(stdout, usage)
			return 0
		}
		// Otherwise flag already reported it and fs.Usage printed usage.
		return 2
	}

	switch {
	case showVersion:
		fmt.Fprintf(stdout, "ytt %s\n", version)
		return 0
	case helpAgent:
		guide, err := embedded.ReadFile("agents-guide.md")
		if err != nil {
			fmt.Fprintf(stderr, "ytt: reading embedded agent guide: %v\n", err)
			return 1
		}
		// Usage first, then the guide: one call gives an agent both.
		fmt.Fprint(stdout, usage)
		fmt.Fprintf(stdout, "\n---\n\n%s", guide)
		return 0
	}

	if timestamps && asJSON {
		fmt.Fprintln(stderr, "ytt: --timestamps and --json are mutually exclusive")
		return 2
	}

	videos := fs.Args()
	if len(videos) == 0 {
		fmt.Fprintln(stderr, "ytt: at least one VIDEO argument is required")
		fmt.Fprint(stderr, usage)
		return 2
	}

	mode := "plain"
	if asJSON {
		mode = "json"
	} else if timestamps {
		mode = "timestamps"
	}

	ctx := context.Background()
	exitCode := 0
	for i, raw := range videos {
		// Text modes separate videos with a blank line; JSON mode is JSONL,
		// where each object's trailing newline is the only separator.
		if i > 0 && mode != "json" {
			fmt.Fprintln(stdout)
		}
		id := ExtractVideoID(raw)
		t, err := fetch(ctx, &FetchArgs{VideoID: id, YtDlpBin: os.Getenv("YTT_YT_DLP_BIN")})
		if err != nil {
			// A missing transcript is reported distinctly from a fetch
			// failure: the first is a property of the video, the second is
			// something wrong with us or the network.
			if errors.Is(err, ErrNoTranscript) {
				fmt.Fprintf(stderr, "ytt: %s: no transcript available\n", id)
			} else {
				fmt.Fprintf(stderr, "ytt: %s: %v\n", id, err)
			}
			exitCode = 1
			continue
		}
		out, err := t.Render(mode)
		if err != nil {
			fmt.Fprintf(stderr, "ytt: %s: %v\n", id, err)
			exitCode = 1
			continue
		}
		fmt.Fprintln(stdout, out)
	}
	return exitCode
}

// runIngest execs the bundled ingest workflow.
//
// The scripts are resolved relative to the executable because they are part of
// the same package — unlike user configuration, which must never be resolved
// that way (a package-managed prefix is replaced wholesale on upgrade; doing
// this to channels.yaml cost fifteen days of silent no-ops).
func runIngest(args []string, stdout, stderr io.Writer) int {
	script, err := ingestScript()
	if err != nil {
		fmt.Fprintf(stderr, "ytt: %v\n", err)
		return 1
	}
	cmd := exec.Command(script, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, stdout, stderr
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			if st, ok := ee.Sys().(syscall.WaitStatus); ok {
				return st.ExitStatus()
			}
			return 1
		}
		fmt.Fprintf(stderr, "ytt: running ingest: %v\n", err)
		return 1
	}
	return 0
}

func ingestScript() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("locating the ytt binary: %w", err)
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	dir := filepath.Dir(exe)
	// Installed layout puts the binary in libexec beside scripts/; a source
	// checkout has scripts/ beside the built binary. Try both, and the parent
	// for a bin/ -> libexec/ arrangement.
	candidates := []string{
		filepath.Join(dir, "scripts", "playlist-ingest", "ingest.sh"),
		filepath.Join(dir, "..", "libexec", "scripts", "playlist-ingest", "ingest.sh"),
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c, nil
		}
	}
	return "", fmt.Errorf("ingest script not found near %s "+
		"(this build was not packaged with the playlist-ingest scripts)", dir)
}
