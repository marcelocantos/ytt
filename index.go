// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Regenerate the knowledge-base index by scanning all per-video synopsis files.
//
// The synopsis format consumed here (the TL;DR line prefix, the "single
// non-transcript *.md" locator) is defined in
// scripts/playlist-ingest/synopsis-contract.md — its "Machine contract"
// section. Change the format there and the parsing here in the same diff.
//
// Output: $ROOT/youtube-knowledge-base.md — a two-column markdown table of
// videos uploaded in the last YOUTUBE_INDEX_RECENT_DAYS (default 7), sorted
// newest first. Older synopses stay on disk and are omitted from the page.
// The first column stacks title (linked to the synopsis), channel, and
// date · duration; the second carries the TL;DR, falling back to the first
// sentence of the Synopsis section for legacy entries.
//
// The filename serves as the page title (no in-doc H1) so GitHub and Obsidian
// render it without a duplicate heading. An H2 Scope line states the window
// and how many ingested synopses were omitted.

// videoMeta is the subset of yt-dlp's metadata the index uses.
type videoMeta struct {
	Title      string  `json:"title"`
	Channel    string  `json:"channel"`
	Uploader   string  `json:"uploader"`
	UploadDate string  `json:"upload_date"`
	Duration   float64 `json:"duration"`
	WebpageURL string  `json:"webpage_url"`

	// durationRaw preserves whether the source value was integral. The shell
	// implementation tested the raw JSON text against ^[0-9]+$ and rendered a
	// dash for anything else, including a fractional duration; keeping that
	// behaviour avoids a cosmetic diff across the whole index on first run.
	durationIsInt bool
}

const missing = "–" // en dash, as the shell implementation emitted

var tldrRe = regexp.MustCompile(`^\*\*TL;DR\*\*:[[:space:]]*`)

var caveatRe = regexp.MustCompile(`^\*\*Caveat\*\*:[[:space:]]*`)

// sentenceEnd trims a fallback line to its first sentence.
var sentenceEnd = regexp.MustCompile(`([.!?]).*`)

func cmdBuildIndex(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("build-index", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	root := os.Getenv("YOUTUBE_INGEST_ROOT")
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintf(stderr, "ytt: locating home directory: %v\n", err)
			return 1
		}
		root = filepath.Join(home, "think", "knowledge", "youtube")
	}
	index := filepath.Join(root, "youtube-knowledge-base.md")

	rows, err := collectRows(root)
	if err != nil {
		fmt.Fprintf(stderr, "ytt: %v\n", err)
		return 1
	}

	now := indexNow()
	days := recentIndexDays()
	shown := filterRecent(rows, now, days)

	var b strings.Builder
	b.WriteString(indexPreamble(shown, len(rows), days, now))
	b.WriteString("| Video | TL;DR |\n")
	b.WriteString("|-------|-------|\n")
	for _, r := range shown {
		b.WriteString(r.row)
		b.WriteByte('\n')
	}

	if err := os.WriteFile(index, []byte(b.String()), 0o644); err != nil {
		fmt.Fprintf(stderr, "ytt: writing index: %v\n", err)
		return 1
	}
	if days > 0 && len(shown) != len(rows) {
		fmt.Fprintf(stderr, "wrote %s (%d of %d entries, last %d days)\n",
			index, len(shown), len(rows), days)
	} else {
		fmt.Fprintf(stderr, "wrote %s (%d entries)\n", index, len(shown))
	}
	return 0
}

const defaultRecentIndexDays = 7

func recentIndexDays() int {
	s := strings.TrimSpace(os.Getenv("YOUTUBE_INDEX_RECENT_DAYS"))
	if s == "" {
		return defaultRecentIndexDays
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return defaultRecentIndexDays
	}
	return n
}

func indexNow() time.Time {
	s := strings.TrimSpace(os.Getenv("YOUTUBE_INDEX_AS_OF"))
	if s == "" {
		return time.Now()
	}
	if t, err := time.ParseInLocation("2006-01-02", s, time.Local); err == nil {
		return t
	}
	return time.Now()
}

func calendarDate(t time.Time) time.Time {
	y, m, d := t.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, t.Location())
}

func parseUploadDate(s string) (time.Time, bool) {
	if len(s) != 8 {
		return time.Time{}, false
	}
	t, err := time.ParseInLocation("20060102", s, time.Local)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// filterRecent keeps rows whose YouTube upload_date is on or after
// today minus days. days <= 0 means no cutoff. Undated rows are dropped
// when a window is active — they are not "recent".
func filterRecent(rows []indexRow, now time.Time, days int) []indexRow {
	if days <= 0 {
		return rows
	}
	cutoff := calendarDate(now).AddDate(0, 0, -days)
	out := make([]indexRow, 0, len(rows))
	for _, r := range rows {
		d, ok := parseUploadDate(r.sortKey)
		if !ok {
			continue
		}
		if !d.Before(cutoff) {
			out = append(out, r)
		}
	}
	return out
}

type indexRow struct {
	// sortKey is the upload date, or "00000000" when unknown, so undated
	// entries sink to the bottom.
	sortKey string
	row     string
}

func collectRows(root string) ([]indexRow, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading %s: %w", root, err)
	}

	var rows []indexRow
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		id := entry.Name()
		dir := filepath.Join(root, id)
		synopsis, slug := findSynopsis(dir)
		if synopsis == "" {
			continue
		}

		meta := readMeta(filepath.Join(dir, "meta.json"), id)
		tldr, caveat := extractTLDR(synopsis)

		url := meta.WebpageURL
		if url == "" {
			url = "https://www.youtube.com/watch?v=" + id
		}
		cell := escapePipes(tldr)
		if caveat != "" {
			cell += formatIndexCaveat(caveat)
		}
		row := fmt.Sprintf("| **[%s](%s/%s)** ([yt](%s))<br>%s<br>%s · %s | %s |",
			escapePipes(meta.Title), id, slug, url,
			escapePipes(channelOf(meta)),
			formatDate(meta.UploadDate), formatDuration(meta),
			cell)

		key := meta.UploadDate
		if key == "" {
			key = "00000000"
		}
		rows = append(rows, indexRow{sortKey: key, row: row})
	}

	// The shell implementation sorted the tab-joined "key\trow" lines with
	// `sort -r`, i.e. reverse lexicographic over the whole line. Replicated
	// exactly, so ties break identically rather than by directory order.
	sort.Slice(rows, func(i, j int) bool {
		a := rows[i].sortKey + "\t" + rows[i].row
		b := rows[j].sortKey + "\t" + rows[j].row
		return a > b
	})
	return rows, nil
}

// findSynopsis returns the synopsis path and its basename: the single *.md in
// dir that is not a transcript, and is non-empty.
//
// Entries are considered in sorted order. The shell version used `find
// -print -quit`, which took whatever the filesystem offered first; sorting
// makes the choice deterministic when a directory somehow holds two.
func findSynopsis(dir string) (path, slug string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", ""
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".md") || strings.HasPrefix(name, "transcript") {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		full := filepath.Join(dir, name)
		if st, err := os.Stat(full); err == nil && st.Size() > 0 {
			return full, name
		}
	}
	return "", ""
}

func readMeta(path, id string) videoMeta {
	// A missing meta.json is normal for a hand-added entry; fall back to the
	// video id rather than skipping the row.
	m := videoMeta{Title: id}
	data, err := os.ReadFile(path)
	if err != nil {
		return m
	}
	// Decode twice: once into the struct, once loosely so the raw duration
	// token can be checked for integrality.
	if err := json.Unmarshal(data, &m); err != nil {
		return videoMeta{Title: id}
	}
	if m.Title == "" {
		m.Title = "(unknown)"
	}
	var loose map[string]json.RawMessage
	if err := json.Unmarshal(data, &loose); err == nil {
		if raw, ok := loose["duration"]; ok {
			tok := strings.TrimSpace(string(raw))
			m.durationIsInt = tok != "" && !strings.ContainsAny(tok, ".eE") && tok[0] != '-'
		}
	}
	return m
}

// channelOf mirrors jq's `.channel // .uploader // "–"`.
func channelOf(m videoMeta) string {
	if m.Channel != "" {
		return m.Channel
	}
	if m.Uploader != "" {
		return m.Uploader
	}
	return missing
}

func formatDuration(m videoMeta) string {
	secs := int(m.Duration)
	if !m.durationIsInt || secs <= 0 {
		return missing
	}
	return fmt.Sprintf("%d:%02d", secs/60, secs%60)
}

// indexPreamble is the page header: generator stamp plus a Scope heading.
// When days > 0 the page is a recent-upload window (shown of total);
// synopses outside the window stay on disk. days <= 0 is the full catalog.
func indexPreamble(shown []indexRow, total, days int, now time.Time) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Auto-generated by `ytt build-index`. Last updated %s.\n\n",
		now.Format("2006-01-02T15:04-0700"))
	b.WriteString("## Scope\n\n")
	n := len(shown)
	min, max := dateSpan(shown)
	noun := "videos"
	if n == 1 {
		noun = "video"
	}
	if days <= 0 {
		switch {
		case total == 0:
			b.WriteString("Every ingested synopsis in this tree. Empty — nothing ingested yet.\n\n")
		case min == "":
			fmt.Fprintf(&b, "Every ingested synopsis in this tree (%d %s). Upload dates are unknown.\n\n", n, noun)
		case min == max:
			fmt.Fprintf(&b, "Every ingested synopsis in this tree (%d %s), uploaded %s. Full catalog, sorted newest first.\n\n", n, noun, formatDate(min))
		default:
			fmt.Fprintf(&b, "Every ingested synopsis in this tree (%d %s), YouTube upload dates %s through %s. Full catalog, sorted newest first.\n\n", n, noun, formatDate(min), formatDate(max))
		}
		return b.String()
	}
	cutoff := formatDate(calendarDate(now).AddDate(0, 0, -days).Format("20060102"))
	switch {
	case total == 0:
		b.WriteString("Videos uploaded in the last " + strconv.Itoa(days) + " days. Empty — nothing ingested yet.\n\n")
	case n == 0:
		fmt.Fprintf(&b, "Videos uploaded on or after %s (last %d days). None of the %d ingested synopses fall in this window; they stay on disk in their video directories.\n\n", cutoff, days, total)
	case min == max:
		fmt.Fprintf(&b, "Videos uploaded on or after %s (last %d days): %d of %d ingested synopses, uploaded %s, sorted newest first. Synopses outside this window stay on disk.\n\n", cutoff, days, n, total, formatDate(min))
	default:
		fmt.Fprintf(&b, "Videos uploaded on or after %s (last %d days): %d of %d ingested synopses, %s through %s, sorted newest first. Synopses outside this window stay on disk.\n\n", cutoff, days, n, total, formatDate(min), formatDate(max))
	}
	return b.String()
}

func dateSpan(rows []indexRow) (min, max string) {
	for _, r := range rows {
		if r.sortKey == "" || r.sortKey == "00000000" {
			continue
		}
		if min == "" || r.sortKey < min {
			min = r.sortKey
		}
		if max == "" || r.sortKey > max {
			max = r.sortKey
		}
	}
	return min, max
}

func formatDate(d string) string {
	if len(d) != 8 {
		return missing
	}
	for _, r := range d {
		if r < '0' || r > '9' {
			return missing
		}
	}
	return d[0:4] + "-" + d[4:6] + "-" + d[6:8]
}

// escapePipes keeps a cell from breaking the markdown table.
func escapePipes(s string) string {
	return strings.ReplaceAll(s, "|", `\|`)
}

// formatIndexCaveat renders a Caveat remainder under the TL;DR. New
// synopses start the remainder with ⚠️ and/or 👎; those are kept as
// written. A legacy unmarked line (Caveat-iff-Critique era) is prefixed
// 👎 so existing entries do not change meaning.
func formatIndexCaveat(caveat string) string {
	s := strings.TrimSpace(caveat)
	if s == "" {
		return ""
	}
	if strings.HasPrefix(s, "⚠") || strings.HasPrefix(s, "👎") {
		return "<br>" + escapePipes(s)
	}
	return "<br>👎 " + escapePipes(s)
}

// extractTLDR pulls the summary out of a synopsis: the first **TL;DR**: line,
// else the first non-empty line of the Synopsis section trimmed to one
// sentence (legacy entries predate the TL;DR convention). It also returns the
// first **Caveat**: line, or "" when the synopsis has none.
func extractTLDR(path string) (tldr, caveat string) {
	f, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer f.Close()

	var fallback string
	inSynopsis := false
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if tldr == "" && tldrRe.MatchString(line) {
			// The first TL;DR wins outright over any fallback.
			tldr = tldrRe.ReplaceAllString(line, "")
			continue
		}
		if caveat == "" && caveatRe.MatchString(line) {
			caveat = caveatRe.ReplaceAllString(line, "")
			continue
		}
		if tldr != "" && caveat != "" {
			return tldr, caveat
		}
		if fallback != "" {
			continue // keep scanning for TL;DR/Caveat; the fallback is settled
		}
		switch {
		case strings.HasPrefix(line, "## Synopsis"):
			inSynopsis = true
		case inSynopsis && strings.HasPrefix(line, "## "):
			inSynopsis = false
		case inSynopsis && strings.TrimSpace(line) != "":
			fallback = sentenceEnd.ReplaceAllString(line, "$1")
		}
	}
	if tldr == "" {
		tldr = fallback
	}
	return tldr, caveat
}
