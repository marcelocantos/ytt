// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The README configuration table is the only user-facing list of ingest
// knobs. Nine variables had drifted out of it by v0.14.0 (they were read by
// the scripts and Go code but never documented), so the table is ratcheted
// here: every YOUTUBE_* / YTT_* name appearing anywhere in the shipped
// sources — the Go files of the module and the bundled shell scripts — must
// have a row, unless it is listed in envNotConfigurable below with a reason.
//
// The scan is deliberately blunt: any mention of a matching name counts,
// including one in a comment. A knob documented in a script's header but
// dropped from the README is exactly the drift this catches, and the cost of
// bluntness is a short, explicit allowlist rather than a silent filter on the
// syntactic form of the read.
const envNamePattern = `\b(?:YOUTUBE|YTT)_[A-Z0-9_]+`

var (
	envName = regexp.MustCompile(envNamePattern)
	// A README row's first cell, e.g. "| `YOUTUBE_INGEST_ROOT` | ..." or
	// "| `A`, `B` | ...". Each backticked token is one documented variable.
	readmeRow      = regexp.MustCompile(`(?m)^\|([^|]*)\|`)
	readmeCellName = regexp.MustCompile("`(" + envNamePattern + ")`")
)

// Names that match the pattern but are not user-facing configuration, each
// with the reason it needs no README row. Keep this short: an entry here is a
// promise that the name never reaches a user, not a way to silence the gate.
var envNotConfigurable = map[string]string{
	// A shell local in ingest.sh / ingest-one.sh holding the resolved path of
	// the ytt executable. It is assigned from $YOUTUBE_INGEST_YTT_BIN (which
	// is documented) and never read from the environment.
	"YTT_BIN": "shell local, assigned from $YOUTUBE_INGEST_YTT_BIN",
}

// The bats suite and its helpers export variables to drive the scripts,
// including knobs the scripts stopped reading long ago
// ($YOUTUBE_INGEST_SLACK_WEBHOOK and friends). Documenting those would be a
// lie, so the fixtures are not sources: the product code is the authority.
const shellTestDir = "scripts/playlist-ingest/tests"

func TestReadmeDocumentsEveryEnvVarInTheSources(t *testing.T) {
	read := map[string][]string{} // variable -> files that mention it
	err := filepath.WalkDir(".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".git" || filepath.ToSlash(path) == shellTestDir {
				return fs.SkipDir
			}
			return nil
		}
		ext := filepath.Ext(path)
		isSource := ext == ".sh" || (ext == ".go" && !strings.HasSuffix(path, "_test.go"))
		if !isSource {
			return nil
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, name := range envName.FindAllString(string(body), -1) {
			read[name] = append(read[name], path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(read) == 0 {
		t.Fatal("found no env-var names in the sources; the pattern no longer matches")
	}

	readme, err := os.ReadFile("README.md")
	if err != nil {
		t.Fatal(err)
	}
	documented := map[string]bool{}
	for _, row := range readmeRow.FindAllStringSubmatch(string(readme), -1) {
		for _, m := range readmeCellName.FindAllStringSubmatch(row[1], -1) {
			documented[m[1]] = true
		}
	}

	names := make([]string, 0, len(read))
	for name := range read {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if documented[name] {
			continue
		}
		if reason, ok := envNotConfigurable[name]; ok {
			t.Logf("%s: no README row, allowed (%s)", name, reason)
			continue
		}
		t.Errorf("%s appears in %s but has no row in the README configuration table; "+
			"add one, or add it to envNotConfigurable with a reason",
			name, strings.Join(dedupe(read[name]), ", "))
	}

	// An allowlist that outlives the code it excuses is a hole waiting for a
	// name to fall into.
	for name, reason := range envNotConfigurable {
		if len(read[name]) == 0 {
			t.Errorf("envNotConfigurable lists %s (%s) but no source mentions it; remove the entry",
				name, reason)
		}
	}
}

func dedupe(paths []string) []string {
	seen := map[string]bool{}
	out := paths[:0:0]
	for _, p := range paths {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out
}
