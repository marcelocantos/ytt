// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The end-to-end behaviour is covered by scripts/playlist-ingest/tests/
// build-index.bats, kept from the shell implementation as a black-box harness.
// These cover the parsing and formatting edges more cheaply.

func writeVideo(t *testing.T, root, id, meta, slug, body string) {
	t.Helper()
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if meta != "" {
		if err := os.WriteFile(filepath.Join(dir, "meta.json"), []byte(meta), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, slug), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestExtractTLDRPrefersTLDRLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.md")
	os.WriteFile(path, []byte("# T\n**TL;DR**: The summary.\n\n## Synopsis\nBody text.\n"), 0o644)
	got, caveat := extractTLDR(path)
	if got != "The summary." {
		t.Errorf("got %q", got)
	}
	if caveat != "" {
		t.Errorf("caveat = %q, want empty when no Caveat line", caveat)
	}
}

func TestExtractTLDRReturnsCaveat(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.md")
	os.WriteFile(path, []byte("# T\n**TL;DR**: The summary.\n\n**Caveat**: Founder marketing.\n\n## Synopsis\nBody.\n"), 0o644)
	got, caveat := extractTLDR(path)
	if got != "The summary." {
		t.Errorf("tldr = %q", got)
	}
	if caveat != "Founder marketing." {
		t.Errorf("caveat = %q", caveat)
	}
}

func TestExtractTLDRCaveatWithFallbackSummary(t *testing.T) {
	// A legacy entry without a TL;DR line can still carry a Caveat.
	dir := t.TempDir()
	path := filepath.Join(dir, "s.md")
	os.WriteFile(path, []byte("# T\n\n**Caveat**: Sponsored.\n\n## Synopsis\nFirst stands in. Rest dropped.\n"), 0o644)
	got, caveat := extractTLDR(path)
	if got != "First stands in." {
		t.Errorf("tldr = %q", got)
	}
	if caveat != "Sponsored." {
		t.Errorf("caveat = %q", caveat)
	}
}

func TestExtractTLDRFallsBackToFirstSentence(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.md")
	os.WriteFile(path, []byte("# T\n\n## Synopsis\nFirst stands in. Second is dropped.\n"), 0o644)
	if got, _ := extractTLDR(path); got != "First stands in." {
		t.Errorf("got %q, want the first sentence only", got)
	}
}

func TestExtractTLDRStopsAtNextSection(t *testing.T) {
	// A Synopsis section that is empty must not borrow text from the section
	// after it.
	dir := t.TempDir()
	path := filepath.Join(dir, "s.md")
	os.WriteFile(path, []byte("## Synopsis\n\n## Key Takeaways\nNot this.\n"), 0o644)
	if got, _ := extractTLDR(path); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

func TestFormatDate(t *testing.T) {
	cases := map[string]string{
		"20260101": "2026-01-01",
		"":         missing,
		"2026":     missing,
		"2026010a": missing,
	}
	for in, want := range cases {
		if got := formatDate(in); got != want {
			t.Errorf("formatDate(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFormatDuration(t *testing.T) {
	cases := []struct {
		secs  float64
		isInt bool
		want  string
	}{
		{120, true, "2:00"},
		{125, true, "2:05"},
		{3661, true, "61:01"}, // minutes are not capped at 59
		{0, true, missing},
		{-5, true, missing},
		{120.5, false, missing}, // a fractional duration rendered a dash before
	}
	for _, c := range cases {
		got := formatDuration(videoMeta{Duration: c.secs, durationIsInt: c.isInt})
		if got != c.want {
			t.Errorf("formatDuration(%v,int=%v) = %q, want %q", c.secs, c.isInt, got, c.want)
		}
	}
}

func TestEscapePipes(t *testing.T) {
	if got := escapePipes("a | b | c"); got != `a \| b \| c` {
		t.Errorf("got %q", got)
	}
}

func TestFormatIndexCaveatHonoursMarkers(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", ""},
		{"Founder marketing.", "<br>👎 Founder marketing."},
		{"⚠️ Founder marketing.", "<br>⚠️ Founder marketing."},
		{"⚠ Treat as pitch.", "<br>⚠ Treat as pitch."},
		{"👎 The 10x claim is contradicted.", "<br>👎 The 10x claim is contradicted."},
		{"⚠️ Founder pitch. 👎 The 10x claim is contradicted.", "<br>⚠️ Founder pitch. 👎 The 10x claim is contradicted."},
		{"  ⚠️ Sponsored.  ", "<br>⚠️ Sponsored."},
	}
	for _, c := range cases {
		if got := formatIndexCaveat(c.in); got != c.want {
			t.Errorf("formatIndexCaveat(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestChannelFallsBackToUploaderThenDash(t *testing.T) {
	if got := channelOf(videoMeta{Channel: "c", Uploader: "u"}); got != "c" {
		t.Errorf("got %q, want the channel", got)
	}
	if got := channelOf(videoMeta{Uploader: "u"}); got != "u" {
		t.Errorf("got %q, want the uploader", got)
	}
	if got := channelOf(videoMeta{}); got != missing {
		t.Errorf("got %q, want a dash", got)
	}
}

func TestCollectRowsSortsNewestFirst(t *testing.T) {
	root := t.TempDir()
	writeVideo(t, root, "OLD00000000",
		`{"title":"Older","channel":"c","upload_date":"20260101","duration":120}`,
		"older.md", "**TL;DR**: old.\n")
	writeVideo(t, root, "NEW00000000",
		`{"title":"Newer","channel":"c","upload_date":"20260601","duration":120}`,
		"newer.md", "**TL;DR**: new.\n")

	rows, err := collectRows(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2", len(rows))
	}
	if !strings.Contains(rows[0].row, "Newer") {
		t.Errorf("first row should be the newer video, got %q", rows[0].row)
	}
}

func TestCollectRowsSkipsTranscriptsAndEmptyFiles(t *testing.T) {
	root := t.TempDir()
	// A transcript-named md and an empty synopsis must both be ignored, which
	// is what stops a half-ingested directory appearing in the index.
	dir := filepath.Join(root, "VID00000000")
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "transcript.md"), []byte("not a synopsis"), 0o644)
	os.WriteFile(filepath.Join(dir, "empty.md"), []byte(""), 0o644)

	rows, err := collectRows(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Errorf("got %d rows, want 0: %+v", len(rows), rows)
	}
}

func TestCollectRowsMissingMetaUsesVideoID(t *testing.T) {
	root := t.TempDir()
	writeVideo(t, root, "NOMETA00000", "", "s.md", "**TL;DR**: x.\n")
	rows, err := collectRows(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1", len(rows))
	}
	if !strings.Contains(rows[0].row, "NOMETA00000") {
		t.Errorf("row should fall back to the id: %q", rows[0].row)
	}
	// An undated entry sinks to the bottom via the 00000000 key.
	if rows[0].sortKey != "00000000" {
		t.Errorf("sortKey = %q, want 00000000", rows[0].sortKey)
	}
}

func TestCollectRowsFallsBackToWatchURL(t *testing.T) {
	root := t.TempDir()
	writeVideo(t, root, "NOURL000000",
		`{"title":"T","channel":"c","upload_date":"20260101","duration":60}`,
		"s.md", "**TL;DR**: x.\n")
	rows, _ := collectRows(root)
	if len(rows) != 1 || !strings.Contains(rows[0].row, "watch?v=NOURL000000") {
		t.Errorf("row should synthesise a watch URL: %+v", rows)
	}
}
