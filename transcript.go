// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// ErrNoTranscript means the video exists but has no usable caption track.
//
// This has to be a distinct, explicit error rather than an empty result.
// yt-dlp exits 0 and simply writes no subtitle file when a video has no
// captions, so a port that only checks the exit status silently converts "no
// transcript" into "empty transcript" — a member of the silent-degradation
// class that has caused every hard-to-find bug in this project.
var ErrNoTranscript = errors.New("no transcript available")

// Snippet is one caption cue.
type Snippet struct {
	Text     string  `json:"text"`
	Start    float64 `json:"start"`
	Duration float64 `json:"duration"`
}

// MarshalJSON renders seconds the way Python's json.dumps did, so the payload
// is byte-identical to the previous implementation's rather than merely
// numerically equal.
//
// Go's encoder emits an integral float64 as `0`; Python emits `0.0`. The values
// are the same number and every consumer here parses the JSON, so this is
// cosmetic — but making it exact costs a few lines and removes a caveat that
// would otherwise have to be remembered every time this output is compared.
func (s Snippet) MarshalJSON() ([]byte, error) {
	text, err := json.Marshal(s.Text)
	if err != nil {
		return nil, err
	}
	return []byte(fmt.Sprintf(`{"text":%s,"start":%s,"duration":%s}`,
		text, pyFloat(s.Start), pyFloat(s.Duration))), nil
}

// pyFloat formats a float64 as Python's repr would: shortest round-trip form,
// with a trailing ".0" on integral values.
func pyFloat(f float64) string {
	out := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.ContainsAny(out, ".eE") {
		out += ".0"
	}
	return out
}

// Transcript mirrors the public surface the Python implementation exposed, so
// the `--json` payload is unchanged for downstream consumers.
type Transcript struct {
	VideoID      string    `json:"video_id"`
	Language     string    `json:"language"`
	LanguageCode string    `json:"language_code"`
	IsGenerated  bool      `json:"is_generated"`
	Snippets     []Snippet `json:"snippets"`
}

// FetchArgs configures a transcript fetch. A struct rather than variadic
// options, per the Go conventions in ~/.claude/go.md.
type FetchArgs struct {
	VideoID string
	// Langs is the language preference order. Empty means []string{"en"}.
	Langs []string
	// YtDlpBin is the yt-dlp executable; empty means "yt-dlp" from PATH.
	YtDlpBin string
}

// json3Doc is yt-dlp's json3 subtitle format.
type json3Doc struct {
	Events []struct {
		TStartMs    *int `json:"tStartMs"`
		DDurationMs *int `json:"dDurationMs"`
		Segs        []struct {
			Utf8 string `json:"utf8"`
		} `json:"segs"`
	} `json:"events"`
}

// ytDlpMeta is the subset of yt-dlp's --print-json output we need.
type ytDlpMeta struct {
	ID                 string                    `json:"id"`
	Subtitles          map[string][]ytDlpSubInfo `json:"subtitles"`
	AutomaticCaptions  map[string][]ytDlpSubInfo `json:"automatic_captions"`
	RequestedSubtitles map[string]ytDlpSubInfo   `json:"requested_subtitles"`
}

type ytDlpSubInfo struct {
	Ext  string `json:"ext"`
	Name string `json:"name"`
}

// Fetch retrieves a transcript by delegating to yt-dlp.
//
// yt-dlp rather than a Go YouTube library, deliberately: YouTube changes its
// internal caption APIs constantly, and yt-dlp absorbs that churn with a large
// community and near-daily releases. A small Go package would rot and leave us
// owning breakage in the component whose failure is hardest to detect. yt-dlp
// is already a hard dependency of the ingest pipeline, so this removes a
// dependency (youtube-transcript-api) rather than adding one.
//
// One invocation supplies both the caption file and the language metadata:
// --print-json emits the metadata while --write-subs writes the track.
func Fetch(ctx context.Context, args *FetchArgs) (*Transcript, error) {
	langs := args.Langs
	if len(langs) == 0 {
		langs = []string{"en"}
	}
	bin := args.YtDlpBin
	if bin == "" {
		bin = "yt-dlp"
	}

	dir, err := os.MkdirTemp("", "ytt-subs-*")
	if err != nil {
		return nil, fmt.Errorf("creating temp dir: %w", err)
	}
	defer os.RemoveAll(dir)

	// --write-subs before --write-auto-subs so a human-authored track wins
	// over ASR when both exist, matching the Python library's preference.
	cmd := exec.CommandContext(ctx, bin,
		"--skip-download",
		"--write-subs", "--write-auto-subs",
		"--sub-langs", strings.Join(langs, ","),
		"--sub-format", "json3",
		"--print-json",
		"--no-warnings",
		"-o", filepath.Join(dir, "%(id)s.%(ext)s"),
		"https://www.youtube.com/watch?v="+args.VideoID,
	)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("yt-dlp: %s", firstLine(msg))
	}

	var meta ytDlpMeta
	// --print-json emits one JSON object per entry; take the first line that
	// parses, so a playlist URL or extra output cannot derail us.
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || !strings.HasPrefix(line, "{") {
			continue
		}
		if err := json.Unmarshal([]byte(line), &meta); err == nil && meta.ID != "" {
			break
		}
	}
	if meta.ID == "" {
		return nil, fmt.Errorf("yt-dlp produced no usable metadata for %s", args.VideoID)
	}

	code, path, err := findSubtitleFile(dir, meta, langs)
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading subtitle file: %w", err)
	}
	var doc json3Doc
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("parsing json3 subtitles: %w", err)
	}

	snippets := make([]Snippet, 0, len(doc.Events))
	for _, ev := range doc.Events {
		// Events without segs are layout//timing markers, not text.
		if len(ev.Segs) == 0 || ev.TStartMs == nil {
			continue
		}
		var sb strings.Builder
		for _, seg := range ev.Segs {
			sb.WriteString(seg.Utf8)
		}
		text := sb.String()
		if strings.TrimSpace(text) == "" {
			continue
		}
		dur := 0
		if ev.DDurationMs != nil {
			dur = *ev.DDurationMs
		}
		snippets = append(snippets, Snippet{
			Text: text,
			// json3 carries integer milliseconds; the Python surface exposes
			// seconds as floats, so convert rather than round.
			Start:    float64(*ev.TStartMs) / 1000,
			Duration: float64(dur) / 1000,
		})
	}
	if len(snippets) == 0 {
		return nil, ErrNoTranscript
	}

	generated := true
	if tracks, ok := meta.Subtitles[code]; ok && len(tracks) > 0 {
		generated = false
	}
	name := meta.RequestedSubtitles[code].Name
	if name == "" {
		name = code
	}
	language := name
	if generated {
		// youtube-transcript-api labelled ASR tracks this way; preserved so
		// the --json payload does not change for downstream consumers.
		language += " (auto-generated)"
	}

	return &Transcript{
		VideoID:      meta.ID,
		Language:     language,
		LanguageCode: code,
		IsGenerated:  generated,
		Snippets:     snippets,
	}, nil
}

// findSubtitleFile locates the written track, preferring the caller's language
// order. Returns ErrNoTranscript when yt-dlp wrote nothing — which it does,
// with exit status 0, for a video that simply has no captions.
func findSubtitleFile(dir string, meta ytDlpMeta, langs []string) (code, path string, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", "", fmt.Errorf("reading temp dir: %w", err)
	}
	found := map[string]string{}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".json3") {
			continue
		}
		// <id>.<lang>.json3
		trimmed := strings.TrimSuffix(name, ".json3")
		if i := strings.LastIndex(trimmed, "."); i >= 0 {
			found[trimmed[i+1:]] = filepath.Join(dir, name)
		}
	}
	if len(found) == 0 {
		return "", "", ErrNoTranscript
	}
	for _, want := range langs {
		if p, ok := found[want]; ok {
			return want, p, nil
		}
	}
	// Deterministic fallback so behaviour does not depend on readdir order.
	keys := make([]string, 0, len(found))
	for k := range found {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys[0], found[keys[0]], nil
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// FormatTimestamp renders a cue start as the Python implementation did:
// [MM:SS], widening to [H:MM:SS] past an hour.
func FormatTimestamp(seconds float64) string {
	total := int(seconds)
	h := total / 3600
	m := (total % 3600) / 60
	s := total % 60
	if h > 0 {
		return fmt.Sprintf("[%d:%02d:%02d]", h, m, s)
	}
	return fmt.Sprintf("[%02d:%02d]", m, s)
}

// Render produces the output for one of the three modes. Plain and timestamps
// are byte-compatible with the Python implementation; JSON is compatible after
// the `jq .` normalisation the ingest pipeline already applies (Go and Python
// differ only in inter-token whitespace and integral-float rendering).
func (t *Transcript) Render(mode string) (string, error) {
	switch mode {
	case "json":
		data, err := json.Marshal(t)
		if err != nil {
			return "", fmt.Errorf("encoding transcript: %w", err)
		}
		return string(data), nil
	case "timestamps":
		lines := make([]string, 0, len(t.Snippets))
		for _, s := range t.Snippets {
			lines = append(lines, FormatTimestamp(s.Start)+" "+s.Text)
		}
		return strings.Join(lines, "\n"), nil
	case "plain":
		texts := make([]string, 0, len(t.Snippets))
		for _, s := range t.Snippets {
			texts = append(texts, s.Text)
		}
		return strings.Join(texts, " "), nil
	default:
		return "", fmt.Errorf("unknown mode %q", mode)
	}
}

// ExtractVideoID pulls an ID out of a bare ID or a YouTube URL, matching the
// Python implementation's accepted forms.
func ExtractVideoID(arg string) string {
	if i := strings.Index(arg, "v="); i >= 0 {
		rest := arg[i+2:]
		if j := strings.Index(rest, "&"); j >= 0 {
			rest = rest[:j]
		}
		return rest
	}
	if strings.Contains(arg, "youtu.be/") || strings.Contains(arg, "/shorts/") || strings.Contains(arg, "/embed/") {
		tail := strings.TrimRight(arg, "/")
		if i := strings.LastIndex(tail, "/"); i >= 0 {
			tail = tail[i+1:]
		}
		if j := strings.Index(tail, "?"); j >= 0 {
			tail = tail[:j]
		}
		return tail
	}
	return arg
}
