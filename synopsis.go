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

const synopsisProviderTimeout = 10 * time.Minute

// slugRe recognises a slug line in a reply. It is deliberately looser than the
// contract (2–6 words ending in .md): models routinely drop the .md or run a
// word long, and rejecting those replies left videos failing every tick.
// parseSynopsisReply normalises a match to the contract via slugify.
var slugRe = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*(\.md)?$`)

// providerRun is the seam tests replace. Production talks to Claudia.
type providerRun func(ctx context.Context, provider, model, prompt, workDir string) (string, error)

var runSynopsisProvider providerRun = runClaudiaProvider

var errSynopsisBackend = errors.New("synopsis backend unavailable")

const synopsisBackendExit = 254

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
	providersFlag := fs.String("providers", "", "optional Claudia provider preference or allowlist (not a fallback ladder)")
	check := fs.Bool("check", false, "check background model admission without starting a session")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if !*check && (*dir == "" || *title == "" || *url == "") {
		fmt.Fprintln(stderr, "ytt: synopsis requires --dir, --title, and --url")
		return 2
	}

	if *check {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		pick, err := resolveSynopsisPick(ctx, *providersFlag)
		if err != nil {
			fmt.Fprintf(stderr, "ytt: synopsis preflight: %v\n", err)
			var cap *capacityError
			if errors.As(err, &cap) {
				return 255
			}
			return 1
		}
		fmt.Fprintln(stdout, formatSynopsisPick(pick))
		return 0
	}
	contract, err := loadSynopsisContract()
	if err != nil {
		fmt.Fprintf(stderr, "ytt: synopsis: %v\n", err)
		return 1
	}
	prompt := buildSynopsisPrompt(*dir, *title, *url, contract)
	pick, err := resolveSynopsisPick(context.Background(), *providersFlag)
	if err != nil {
		fmt.Fprintf(stderr, "ytt: synopsis: %v\n", err)
		var cap *capacityError
		if errors.As(err, &cap) {
			return 255
		}
		return synopsisBackendExit
	}
	fmt.Fprintf(stderr, "ytt: synopsis: resolve %s\n", formatSynopsisPick(pick))

	slug, body, used, err := generateSynopsis(context.Background(), pick, prompt, *dir, stderr)
	if err != nil {
		fmt.Fprintf(stderr, "ytt: synopsis: %v\n", err)
		var cap *capacityError
		if errors.As(err, &cap) {
			return 255
		}
		if errors.Is(err, errSynopsisBackend) {
			return synopsisBackendExit
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

// resolveSynopsis is the 🎯T61.5 seam. Claudia Resolve picks one
// (generation, effort) pair from purpose-quality predicates (Session +
// plan + analysis purpose + standard floor + token availability).
// Missing analysis series yields to general inside Claudia. ytt does
// not name a vendor and does not walk a host ladder.
// --providers / YOUTUBE_INGEST_SYNOPSIS_PROVIDERS is a preference (one
// name) or allowlist (several names), not fall-through.
var resolveSynopsis = defaultResolveSynopsis

func defaultResolveSynopsis(ctx context.Context, pred claudia.ModelPredicates) (claudia.ModelPick, error) {
	return claudia.Resolve(ctx, pred)
}

var loadSynopsisPlanUsage = defaultLoadSynopsisPlanUsage

func defaultLoadSynopsisPlanUsage(ctx context.Context) ([]claudia.PlanUsage, error) {
	if !claudia.BrokerAvailable() {
		return nil, claudia.ErrBrokerRequired
	}
	return claudia.LoadPlanUsage(ctx, &claudia.PlanUsageCacheArgs{})
}

func resolveSynopsisPick(ctx context.Context, flagVal string) (claudia.ModelPick, error) {
	names := parseProviderNames(flagVal)
	var prefer claudia.Provider
	var exclude []claudia.Provider
	if len(names) == 1 {
		prefer = names[0]
	} else if len(names) > 1 {
		prefer = names[0]
		exclude = providersNotIn(names)
	}
	usage, err := loadSynopsisPlanUsage(ctx)
	if err != nil {
		// A listening daemon that we cannot speak to is a hard miss.
		// Swallowing it used to pick without plan slack, then fail on
		// Task.Run — or worse, fall through to a direct spawn.
		return claudia.ModelPick{}, err
	}
	if usage == nil {
		usage = []claudia.PlanUsage{}
	}
	pred := claudia.ModelPredicates{
		Mode:             claudia.CapabilitySession,
		Purpose:          claudia.ModelPurposeAnalysis,
		Quality:          claudia.ModelQualityStandard,
		PreferPlan:       true,
		Background:       true,
		PreferProvider:   prefer,
		ExcludeProviders: exclude,
		Usage:            usage,
	}
	pick, err := resolveSynopsis(ctx, pred)
	if err != nil && !synopsisHasPurposeIntel(pred.Intel, claudia.ModelPurposeAnalysis) {
		// Claudia Resolve also yields analysis→general when the series
		// is missing. Keep the host retry so an older pin still does.
		pred.Purpose = claudia.ModelPurposeGeneral
		pick, err = resolveSynopsis(ctx, pred)
	}
	if err != nil && !synopsisHasPurposeIntel(pred.Intel, claudia.ModelPurposeAnalysis) && !synopsisHasPurposeIntel(pred.Intel, claudia.ModelPurposeGeneral) {
		// Purpose-quality needs a series. Until AA ingest has written
		// one, empty Purpose keeps the catalog-shelf path so analyze
		// does not abort every tick.
		pred.Purpose = ""
		pick, err = resolveSynopsis(ctx, pred)
	}
	if err != nil {
		if strings.Contains(err.Error(), "no catalog model matches") {
			return claudia.ModelPick{}, &capacityError{Provider: "all", Msg: err.Error()}
		}
		return claudia.ModelPick{}, err
	}
	return pick, nil
}

func synopsisHasPurposeIntel(args *claudia.ModelIntelArgs, purpose claudia.ModelPurpose) bool {
	latest, err := claudia.LatestModelIntel(args)
	if err != nil {
		return false
	}
	for _, o := range latest {
		if o.Purpose == purpose {
			return true
		}
	}
	return false
}

func parseProviderNames(flagVal string) []claudia.Provider {
	raw := flagVal
	if raw == "" {
		raw = os.Getenv("YOUTUBE_INGEST_SYNOPSIS_PROVIDERS")
	}
	var out []claudia.Provider
	seen := map[claudia.Provider]bool{}
	for _, p := range strings.Split(raw, ",") {
		p = strings.ToLower(strings.TrimSpace(p))
		if p == "" {
			continue
		}
		prov := claudia.Provider(p)
		if seen[prov] {
			continue
		}
		seen[prov] = true
		out = append(out, prov)
	}
	return out
}

func providersNotIn(allow []claudia.Provider) []claudia.Provider {
	ok := map[claudia.Provider]bool{}
	for _, p := range allow {
		ok[p] = true
	}
	seen := map[claudia.Provider]bool{}
	var out []claudia.Provider
	for _, row := range claudia.ModelCatalog() {
		if ok[row.Provider] || seen[row.Provider] {
			continue
		}
		seen[row.Provider] = true
		out = append(out, row.Provider)
	}
	return out
}

func generateSynopsis(ctx context.Context, pick claudia.ModelPick, prompt, workDir string, stderr io.Writer) (slug, body, used string, err error) {
	p := string(pick.Provider)
	pctx, cancel := context.WithTimeout(ctx, synopsisProviderTimeout)
	defer cancel()
	text, runErr := runSynopsisProvider(pctx, p, pick.Model, prompt, workDir)
	if runErr != nil {
		fmt.Fprintf(stderr, "ytt: synopsis: %s failed: %v\n", p, runErr)
		var cap *capacityError
		if errors.As(runErr, &cap) {
			return "", "", "", cap
		}
		if isCapacityText(runErr.Error()) {
			return "", "", "", &capacityError{Provider: p, Msg: runErr.Error()}
		}
		return "", "", "", runErr
	}
	slug, body, parseErr := parseSynopsisReply(text)
	if parseErr != nil {
		fmt.Fprintf(stderr, "ytt: synopsis: %s reply unusable: %v\n", p, parseErr)
		return "", "", "", parseErr
	}
	used = formatSynopsisPick(pick)
	return slug, body, used, nil
}

func formatSynopsisPick(pick claudia.ModelPick) string {
	p := string(pick.Provider)
	if pick.Model == "" {
		return p
	}
	used := p + "/" + pick.Model
	if pick.Effort != "" {
		used += "/" + string(pick.Effort)
	}
	return used
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

	// Agentic replies often open with narration ("Now I have the full
	// transcript. Writing the synopsis.") before the slug line. Skip any
	// leading lines until the first slug or heading; the TL;DR check below
	// still rejects a reply that never gets to a synopsis.
	lines := strings.Split(raw, "\n")
	found := false
	for i, line := range lines {
		first := strings.Trim(strings.TrimSpace(line), "`")
		switch {
		case slugRe.MatchString(first) && !strings.HasPrefix(first, "transcript"):
			slug = slugify(strings.TrimSuffix(first, ".md")) + ".md"
			body = strings.TrimSpace(strings.Join(lines[i+1:], "\n"))
		case strings.HasPrefix(first, "# "):
			slug = slugify(strings.TrimPrefix(first, "# ")) + ".md"
			body = strings.TrimSpace(strings.Join(lines[i:], "\n"))
		default:
			continue
		}
		found = true
		break
	}
	if !found {
		first, _, _ := strings.Cut(raw, "\n")
		return "", "", fmt.Errorf("no slug or heading line; first line: %q", strings.TrimSpace(first))
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
	return fmt.Sprintf(`Read the transcript at %s (YouTube video: %q, %s). The file is ytt's public JSON transcript: a JSON object with video_id, language, language_code, is_generated, and a snippets array of {text, start, duration}. Join snippet text in order for the prose; you may cite [mm:ss] timestamps (from snippet.start) in Key Takeaways when a moment is worth pinning to.

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

func runClaudiaProvider(ctx context.Context, provider, model, prompt, workDir string) (string, error) {
	p, err := claudiaProvider(provider)
	if err != nil {
		return "", err
	}
	// Only the host starts the session. Its read-only tools confine
	// untrusted transcript instructions; YTT writes the returned synopsis.
	agent, err := claudia.StartBrokerContext(ctx, claudia.Config{
		Provider: p, Model: model, WorkDir: workDir,
		SandboxMode: "read-only", ApprovalPolicy: "never", MCPExclusive: true,
	})
	if err != nil {
		if isCapacityText(err.Error()) {
			return "", &capacityError{Provider: provider, Msg: err.Error()}
		}
		return "", fmt.Errorf("%w: %w", errSynopsisBackend, err)
	}
	defer agent.Stop()
	if err := agent.Send(prompt); err != nil {
		return "", fmt.Errorf("%w: %w", errSynopsisBackend, err)
	}
	result, err := agent.WaitForResponse(ctx)
	if err != nil {
		if isCapacityText(err.Error()) {
			return "", &capacityError{Provider: provider, Msg: err.Error()}
		}
		return "", err
	}
	if strings.TrimSpace(result) == "" {
		return "", errors.New("empty result")
	}
	return result, nil
}

func claudiaProvider(name string) (claudia.Provider, error) {
	switch name {
	case "grok", "xai-oauth", "claude", "anthropic", "codex", "openai-codex":
		return claudia.Provider(name), nil
	case "cursor":
		return claudia.ProviderCursor, nil
	default:
		return "", fmt.Errorf("unknown provider %q", name)
	}
}
