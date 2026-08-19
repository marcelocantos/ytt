// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"

	"github.com/marcelocantos/claudia"
)

// Default synopsis ladder: SuperGrok first so the Claude monthly spend
// cap cannot red the whole nightly run; Claude then Codex absorb
// capacity failures.
const defaultSynopsisProviders = "grok,claude,codex"

const synopsisProviderTimeout = 10 * time.Minute

var slugRe = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+){0,5}\.md$`)

// providerRun is the seam tests replace. Production talks to Claudia.
type providerRun func(ctx context.Context, provider, prompt, workDir string) (string, error)

var runSynopsisProvider providerRun = runClaudiaProvider

type capacityError struct {
	Provider string
	Msg      string
}

func (e *capacityError) Error() string {
	return e.Provider + ": capacity: " + e.Msg
}

func cmdSynopsis(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("synopsis", flag.ContinueOnError)
	fs.SetOutput(stderr)
	dir := fs.String("dir", "", "video directory containing meta.json and .transcript/")
	title := fs.String("title", "", "video title")
	url := fs.String("url", "", "YouTube URL")
	providersFlag := fs.String("providers", "", "comma-separated ladder (default grok,claude,codex)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *dir == "" || *title == "" || *url == "" {
		fmt.Fprintln(stderr, "ytt: synopsis requires --dir, --title, and --url")
		return 2
	}

	contract, err := loadSynopsisContract()
	if err != nil {
		fmt.Fprintf(stderr, "ytt: synopsis: %v\n", err)
		return 1
	}
	prompt := buildSynopsisPrompt(*dir, *title, *url, contract)
	providers := parseProviderLadder(*providersFlag)
	if len(providers) == 0 {
		fmt.Fprintln(stderr, "ytt: synopsis: empty provider ladder")
		return 2
	}

	slug, body, used, err := generateSynopsis(context.Background(), providers, prompt, *dir, stderr)
	if err != nil {
		fmt.Fprintf(stderr, "ytt: synopsis: %v\n", err)
		var cap *capacityError
		if errors.As(err, &cap) {
			return 255
		}
		return 1
	}

	path := filepath.Join(*dir, slug)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		fmt.Fprintf(stderr, "ytt: synopsis: writing %s: %v\n", path, err)
		return 1
	}
	fmt.Fprintf(stderr, "synopsis via %s → %s\n", used, slug)
	fmt.Fprintln(stdout, slug)
	return 0
}

func parseProviderLadder(flagVal string) []string {
	raw := flagVal
	if raw == "" {
		raw = os.Getenv("YOUTUBE_INGEST_SYNOPSIS_PROVIDERS")
	}
	if raw == "" {
		raw = defaultSynopsisProviders
	}
	var out []string
	seen := map[string]bool{}
	for _, p := range strings.Split(raw, ",") {
		p = strings.ToLower(strings.TrimSpace(p))
		if p == "" || seen[p] {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	return out
}

func generateSynopsis(ctx context.Context, providers []string, prompt, workDir string, stderr io.Writer) (slug, body, used string, err error) {
	var last error
	var lastCapacity *capacityError
	available := 0
	capacityHits := 0
	for _, p := range providers {
		pctx, cancel := context.WithTimeout(ctx, synopsisProviderTimeout)
		text, runErr := runSynopsisProvider(pctx, p, prompt, workDir)
		cancel()
		if runErr != nil {
			fmt.Fprintf(stderr, "ytt: synopsis: %s failed: %v\n", p, runErr)
			last = runErr
			var cap *capacityError
			if errors.As(runErr, &cap) {
				capacityHits++
				available++
				lastCapacity = cap
				continue
			}
			if isCapacityText(runErr.Error()) {
				capacityHits++
				available++
				lastCapacity = &capacityError{Provider: p, Msg: runErr.Error()}
				continue
			}
			if isUnavailable(runErr) {
				continue
			}
			available++
			continue
		}
		slug, body, parseErr := parseSynopsisReply(text)
		if parseErr != nil {
			fmt.Fprintf(stderr, "ytt: synopsis: %s reply unusable: %v\n", p, parseErr)
			last = parseErr
			available++
			continue
		}
		return slug, body, p, nil
	}
	if available > 0 && capacityHits == available {
		if lastCapacity == nil {
			lastCapacity = &capacityError{Provider: "all", Msg: "every available provider hit a capacity/spend/rate limit"}
		}
		return "", "", "", lastCapacity
	}
	if last == nil {
		last = errors.New("no synopsis provider produced a usable reply")
	}
	return "", "", "", last
}

func isUnavailable(err error) bool {
	if err == nil {
		return false
	}
	s := strings.ToLower(err.Error())
	needles := []string{
		"not found",
		"no such file",
		"executable file not found",
		"cannot find",
		"not installed",
		"auth error",
		"not authenticated",
		"not logged",
		"please log in",
		"subscription auth",
	}
	for _, n := range needles {
		if strings.Contains(s, n) {
			return true
		}
	}
	return false
}

func isCapacityText(s string) bool {
	lower := strings.ToLower(s)
	needles := []string{
		"monthly spend limit",
		"usage limit",
		"spend limit",
		"spending limit",
		"claude.ai/settings/usage",
		"rate limit",
		"rate_limit",
		"quota exceeded",
		"too many requests",
		"resource exhausted",
		"429",
	}
	for _, n := range needles {
		if strings.Contains(lower, n) {
			return true
		}
	}
	return false
}

func parseSynopsisReply(raw string) (slug, body string, err error) {
	raw = strings.TrimSpace(raw)
	raw = strings.TrimPrefix(raw, "```markdown")
	raw = strings.TrimPrefix(raw, "```md")
	raw = strings.TrimPrefix(raw, "```")
	raw = strings.TrimSuffix(raw, "```")
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", "", errors.New("empty reply")
	}

	nl := strings.IndexByte(raw, '\n')
	first, rest := raw, ""
	if nl >= 0 {
		first = strings.TrimSpace(raw[:nl])
		rest = strings.TrimSpace(raw[nl+1:])
	}
	first = strings.Trim(first, "`")

	switch {
	case slugRe.MatchString(first) && !strings.HasPrefix(first, "transcript"):
		slug = first
		body = rest
	case strings.HasPrefix(first, "# "):
		slug = slugify(strings.TrimPrefix(first, "# ")) + ".md"
		body = raw
	default:
		return "", "", fmt.Errorf("first line is not a slug or heading: %q", first)
	}
	if !strings.Contains(body, "**TL;DR**:") {
		return "", "", errors.New("reply missing **TL;DR**: line")
	}
	if !strings.HasSuffix(slug, ".md") || strings.HasPrefix(slug, "transcript") {
		return "", "", fmt.Errorf("bad slug %q", slug)
	}
	if body == "" {
		return "", "", errors.New("empty synopsis body")
	}
	if !strings.HasSuffix(body, "\n") {
		body += "\n"
	}
	return slug, body, nil
}

func slugify(title string) string {
	var b strings.Builder
	words := 0
	inWord := false
	for _, r := range strings.ToLower(title) {
		switch {
		case unicode.IsLetter(r) && r < 128 || unicode.IsDigit(r):
			if !inWord {
				if words >= 6 {
					return b.String()
				}
				if words > 0 {
					b.WriteByte('-')
				}
				words++
				inWord = true
			}
			b.WriteRune(r)
		default:
			inWord = false
		}
	}
	if b.Len() == 0 {
		return "synopsis"
	}
	return b.String()
}

func buildSynopsisPrompt(dir, title, url, contract string) string {
	transcript := filepath.Join(dir, ".transcript", "transcript.json")
	return fmt.Sprintf(`Read the transcript at %s (YouTube video: %q, %s). The file is the full youtube-transcript-api payload: a JSON object with video_id, language, language_code, is_generated, and a snippets array of {text, start, duration}. Join snippet text in order for the prose; you may cite [mm:ss] timestamps (from snippet.start) in Key Takeaways when a moment is worth pinning to.

Produce a detailed synopsis and key takeaways for this video, following the output format defined below. Fill "<video title>" with %q and "<youtube URL>" with %s.

Do not write any files. Do not run shell commands. Reply with exactly:
1. A single line: the filename slug (kebab-case.md) per the contract.
2. A blank line.
3. The full markdown file contents.

Nothing else.

-----8<----- output format contract -----8<-----
%s
`, transcript, title, url, title, url, contract)
}

func loadSynopsisContract() (string, error) {
	if p := os.Getenv("YOUTUBE_SYNOPSIS_CONTRACT"); p != "" {
		data, err := os.ReadFile(p)
		if err != nil {
			return "", fmt.Errorf("reading contract %s: %w", p, err)
		}
		return string(data), nil
	}
	path, err := bundledPath("scripts", "playlist-ingest", "synopsis-contract.md")
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("reading contract %s: %w", path, err)
	}
	return string(data), nil
}

func bundledPath(rel ...string) (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("locating the ytt binary: %w", err)
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	dir := filepath.Dir(exe)
	candidates := []string{
		filepath.Join(append([]string{dir}, rel...)...),
		filepath.Join(append([]string{dir, "..", "libexec"}, rel...)...),
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c, nil
		}
	}
	return "", fmt.Errorf("bundled file not found near %s: %s", dir, filepath.Join(rel...))
}

func runClaudiaProvider(ctx context.Context, provider, prompt, workDir string) (string, error) {
	p, err := claudiaProvider(provider)
	if err != nil {
		return "", err
	}
	cfg := claudia.TaskConfig{
		ID:       "ytt-synopsis",
		Provider: p,
		WorkDir:  workDir,
	}
	switch p {
	case claudia.ProviderClaude:
		// Transcript is untrusted input. Strip write/shell/network tools
		// and take the synopsis from stdout; ytt writes the file.
		cfg.DisallowTools = []string{"Bash", "Write", "Edit", "NotebookEdit", "WebFetch", "WebSearch"}
	case claudia.ProviderCodex:
		cfg.SandboxMode = "workspace-write"
		cfg.ApprovalPolicy = "never"
	}
	task := claudia.NewTask(cfg)
	events, err := task.Run(ctx, prompt)
	if err != nil {
		if isCapacityText(err.Error()) {
			return "", &capacityError{Provider: provider, Msg: err.Error()}
		}
		return "", err
	}
	var result, errMsg string
	for ev := range events {
		switch ev.Type {
		case claudia.TaskEventResult:
			result = ev.Content
		case claudia.TaskEventError:
			errMsg = ev.ErrorMsg
			if errMsg == "" {
				errMsg = ev.Content
			}
		}
	}
	if errMsg != "" {
		if isCapacityText(errMsg) {
			return "", &capacityError{Provider: provider, Msg: errMsg}
		}
		return "", errors.New(errMsg)
	}
	if strings.TrimSpace(result) == "" {
		return "", errors.New("empty result")
	}
	return result, nil
}

func claudiaProvider(name string) (claudia.Provider, error) {
	switch name {
	case "grok":
		return claudia.ProviderGrok, nil
	case "claude":
		return claudia.ProviderClaude, nil
	case "codex":
		return claudia.ProviderCodex, nil
	default:
		return "", fmt.Errorf("unknown provider %q", name)
	}
}
