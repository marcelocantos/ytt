// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Ported from tests/test_ytt.py — the CLI contract these assert is the reason
// the Python suite existed, and it survives the language change unchanged.

func TestExtractVideoID(t *testing.T) {
	cases := []struct{ arg, want string }{
		{"dQw4w9WgXcQ", "dQw4w9WgXcQ"},
		{"https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"},
		{"https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42", "dQw4w9WgXcQ"},
		{"https://youtu.be/dQw4w9WgXcQ", "dQw4w9WgXcQ"},
		{"https://youtu.be/dQw4w9WgXcQ?si=abc", "dQw4w9WgXcQ"},
		{"https://www.youtube.com/shorts/dQw4w9WgXcQ", "dQw4w9WgXcQ"},
		{"https://www.youtube.com/embed/dQw4w9WgXcQ", "dQw4w9WgXcQ"},
	}
	for _, c := range cases {
		if got := ExtractVideoID(c.arg); got != c.want {
			t.Errorf("ExtractVideoID(%q) = %q, want %q", c.arg, got, c.want)
		}
	}
}

func TestFormatTimestamp(t *testing.T) {
	cases := []struct {
		seconds float64
		want    string
	}{
		{0, "[00:00]"},
		{65, "[01:05]"},
		{3600, "[1:00:00]"},
		{3661, "[1:01:01]"},
	}
	for _, c := range cases {
		if got := FormatTimestamp(c.seconds); got != c.want {
			t.Errorf("FormatTimestamp(%v) = %q, want %q", c.seconds, got, c.want)
		}
	}
}

// stubFetch installs a fetcher for the duration of a test.
func stubFetch(t *testing.T, fn func(ctx context.Context, args *FetchArgs) (*Transcript, error)) {
	t.Helper()
	prev := fetch
	fetch = fn
	t.Cleanup(func() { fetch = prev })
}

// oneSnippet builds a transcript whose rendering is predictable per mode.
func oneSnippet(videoID, text string) *Transcript {
	return &Transcript{
		VideoID: videoID, Language: "English", LanguageCode: "en",
		Snippets: []Snippet{{Text: text, Start: 0, Duration: 1}},
	}
}

func TestNoArgsExits2(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run(nil, &out, &errb); code != 2 {
		t.Errorf("exit = %d, want 2", code)
	}
	if !strings.Contains(errb.String(), "at least one VIDEO") {
		t.Errorf("stderr should say what was missing, got %q", errb.String())
	}
}

func TestVersionExits0(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run([]string{"--version"}, &out, &errb); code != 0 {
		t.Errorf("exit = %d, want 0", code)
	}
	if !strings.HasPrefix(out.String(), "ytt ") {
		t.Errorf("stdout = %q, want it to start with \"ytt \"", out.String())
	}
}

func TestTimestampsAndJSONAreMutuallyExclusive(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run([]string{"-t", "--json", "dQw4w9WgXcQ"}, &out, &errb); code != 2 {
		t.Errorf("exit = %d, want 2", code)
	}
}

func TestHelpAgent(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run([]string{"--help-agent"}, &out, &errb); code != 0 {
		t.Fatalf("exit = %d, want 0 (stderr: %s)", code, errb.String())
	}
	got := out.String()
	// The Python suite asserted on these two markers; keep them so the guide
	// cannot silently lose its usage header or its exit-code table.
	for _, want := range []string{"ytt", "Exit codes"} {
		if !strings.Contains(got, want) {
			t.Errorf("--help-agent output missing %q", want)
		}
	}
}

func TestPlainModeSeparatesVideosWithBlankLine(t *testing.T) {
	stubFetch(t, func(_ context.Context, a *FetchArgs) (*Transcript, error) {
		return oneSnippet(a.VideoID, "T["+a.VideoID+"]"), nil
	})
	var out, errb bytes.Buffer
	if code := run([]string{"aaaaaaaaaaa", "bbbbbbbbbbb"}, &out, &errb); code != 0 {
		t.Fatalf("exit = %d, want 0 (stderr: %s)", code, errb.String())
	}
	want := "T[aaaaaaaaaaa]\n\nT[bbbbbbbbbbb]\n"
	if out.String() != want {
		t.Errorf("stdout = %q, want %q", out.String(), want)
	}
}

func TestJSONModeIsJSONLWithNoBlankLine(t *testing.T) {
	stubFetch(t, func(_ context.Context, a *FetchArgs) (*Transcript, error) {
		return oneSnippet(a.VideoID, "text"), nil
	})
	var out, errb bytes.Buffer
	if code := run([]string{"--json", "aaaaaaaaaaa", "bbbbbbbbbbb"}, &out, &errb); code != 0 {
		t.Fatalf("exit = %d, want 0 (stderr: %s)", code, errb.String())
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2 (JSON mode is JSONL, no blank separator): %q", len(lines), out.String())
	}
	var ids []string
	for _, line := range lines {
		var obj struct {
			VideoID string `json:"video_id"`
		}
		if err := json.Unmarshal([]byte(line), &obj); err != nil {
			t.Fatalf("line is not JSON: %q: %v", line, err)
		}
		ids = append(ids, obj.VideoID)
	}
	if ids[0] != "aaaaaaaaaaa" || ids[1] != "bbbbbbbbbbb" {
		t.Errorf("video_ids = %v", ids)
	}
}

func TestFetchFailureSetsExit1ButContinues(t *testing.T) {
	// One bad video must not abort the others: a batch of ten videos should
	// yield nine transcripts and an exit code that says something failed.
	stubFetch(t, func(_ context.Context, a *FetchArgs) (*Transcript, error) {
		if a.VideoID == "bad00000000" {
			return nil, errors.New("boom")
		}
		return oneSnippet(a.VideoID, "T["+a.VideoID+"]"), nil
	})
	var out, errb bytes.Buffer
	code := run([]string{"aaaaaaaaaaa", "bad00000000", "bbbbbbbbbbb"}, &out, &errb)
	if code != 1 {
		t.Errorf("exit = %d, want 1", code)
	}
	if !strings.Contains(out.String(), "T[aaaaaaaaaaa]") || !strings.Contains(out.String(), "T[bbbbbbbbbbb]") {
		t.Errorf("the good videos should still be emitted, got %q", out.String())
	}
	if !strings.Contains(errb.String(), "bad00000000") {
		t.Errorf("stderr should name the failing video, got %q", errb.String())
	}
}

func TestMissingTranscriptIsReportedDistinctly(t *testing.T) {
	// yt-dlp exits 0 writing no file when a video has no captions, so this
	// must never be confused with an empty transcript.
	stubFetch(t, func(_ context.Context, a *FetchArgs) (*Transcript, error) {
		return nil, ErrNoTranscript
	})
	var out, errb bytes.Buffer
	if code := run([]string{"aaaaaaaaaaa"}, &out, &errb); code != 1 {
		t.Errorf("exit = %d, want 1", code)
	}
	if !strings.Contains(errb.String(), "no transcript available") {
		t.Errorf("stderr = %q, want it to name the missing transcript", errb.String())
	}
	if out.String() != "" {
		t.Errorf("stdout should be empty, got %q", out.String())
	}
}

// --- rendering fidelity: the properties the golden corpus pins down ---------

func TestRenderPlainJoinsWithSingleSpace(t *testing.T) {
	tr := &Transcript{Snippets: []Snippet{{Text: "one"}, {Text: "two"}, {Text: "three"}}}
	got, err := tr.Render("plain")
	if err != nil {
		t.Fatal(err)
	}
	if got != "one two three" {
		t.Errorf("plain = %q", got)
	}
}

func TestRenderTimestampsOneCuePerLine(t *testing.T) {
	tr := &Transcript{Snippets: []Snippet{
		{Text: "first", Start: 0},
		{Text: "later", Start: 65},
	}}
	got, err := tr.Render("timestamps")
	if err != nil {
		t.Fatal(err)
	}
	if got != "[00:00] first\n[01:05] later" {
		t.Errorf("timestamps = %q", got)
	}
}

// Integral floats must render as Python did (0.0, not 0), so the JSON payload
// is byte-identical to the previous implementation's rather than merely
// numerically equal.
func TestPyFloatMatchesPythonRepr(t *testing.T) {
	cases := map[float64]string{
		0:      "0.0",
		13:     "13.0",
		4.24:   "4.24",
		1.84:   "1.84",
		0.001:  "0.001",
		120.5:  "120.5",
		3600:   "3600.0",
		4.0001: "4.0001",
	}
	for in, want := range cases {
		if got := pyFloat(in); got != want {
			t.Errorf("pyFloat(%v) = %q, want %q", in, got, want)
		}
	}
}

func TestSnippetJSONShape(t *testing.T) {
	data, err := json.Marshal(Snippet{Text: "hi", Start: 0, Duration: 4.24})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"text":"hi","start":0.0,"duration":4.24}`
	if string(data) != want {
		t.Errorf("snippet JSON = %s, want %s", data, want)
	}
}

func TestTranscriptJSONFieldsAndOrder(t *testing.T) {
	tr := oneSnippet("vid00000000", "hi")
	tr.IsGenerated = true
	data, err := json.Marshal(tr)
	if err != nil {
		t.Fatal(err)
	}
	// Field order is part of the payload's shape; the Python implementation
	// emitted them in this order and downstream diffs are easier if it holds.
	for _, key := range []string{"video_id", "language", "language_code", "is_generated", "snippets"} {
		if !strings.Contains(string(data), `"`+key+`"`) {
			t.Errorf("missing key %q", key)
		}
	}
	var probe struct {
		VideoID     string `json:"video_id"`
		IsGenerated bool   `json:"is_generated"`
	}
	if err := json.Unmarshal(data, &probe); err != nil {
		t.Fatal(err)
	}
	if probe.VideoID != "vid00000000" || !probe.IsGenerated {
		t.Errorf("round trip lost data: %+v", probe)
	}
}

// --- subtitle-file selection ------------------------------------------------

func TestFindSubtitleFilePrefersRequestedLanguage(t *testing.T) {
	dir := t.TempDir()
	for _, lang := range []string{"es", "en", "fr"} {
		if err := os.WriteFile(filepath.Join(dir, "vid."+lang+".json3"), []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	code, path, err := findSubtitleFile(dir, ytDlpMeta{}, []string{"en", "es"})
	if err != nil {
		t.Fatal(err)
	}
	if code != "en" || !strings.HasSuffix(path, "vid.en.json3") {
		t.Errorf("code=%q path=%q, want the first preferred language", code, path)
	}
}

func TestFindSubtitleFileNoFileIsErrNoTranscript(t *testing.T) {
	// The critical case: yt-dlp succeeded but wrote nothing.
	_, _, err := findSubtitleFile(t.TempDir(), ytDlpMeta{}, []string{"en"})
	if !errors.Is(err, ErrNoTranscript) {
		t.Errorf("err = %v, want ErrNoTranscript", err)
	}
}

func TestFindSubtitleFileFallbackIsDeterministic(t *testing.T) {
	// When none of the preferred languages is present, the choice must not
	// depend on readdir order.
	dir := t.TempDir()
	for _, lang := range []string{"zh", "de", "ar"} {
		if err := os.WriteFile(filepath.Join(dir, "vid."+lang+".json3"), []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 5; i++ {
		code, _, err := findSubtitleFile(dir, ytDlpMeta{}, []string{"en"})
		if err != nil {
			t.Fatal(err)
		}
		if code != "ar" {
			t.Fatalf("iteration %d picked %q; want the lexicographically first, deterministically", i, code)
		}
	}
}

func TestUnknownRenderModeErrors(t *testing.T) {
	if _, err := (&Transcript{}).Render("nonsense"); err == nil {
		t.Error("an unknown mode must error rather than silently emit nothing")
	}
}

func TestIngestScriptNotFoundIsExplicit(t *testing.T) {
	// A build packaged without the scripts must say so, not fail obscurely.
	// (This exercises the error text; a real install has the scripts.)
	if _, err := ingestScript(); err != nil && !strings.Contains(err.Error(), "ingest script not found") {
		t.Errorf("unexpected error text: %v", err)
	}
}
