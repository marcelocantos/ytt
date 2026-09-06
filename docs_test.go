// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
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
// here: every `${YOUTUBE_*:-default}` / `${YTT_*:-default}` read in the
// bundled scripts and every os.Getenv("YOUTUBE_*" | "YTT_*") in the Go
// sources must have a row.
//
// Shell reads are matched only in their parameter-default form (`:-`, `:?`,
// `:+`): that is how external configuration enters the scripts, and it
// excludes internal variables such as $YTT_BIN that merely share the prefix.
var (
	shellEnvRead = regexp.MustCompile(`\$\{((?:YOUTUBE|YTT)_[A-Z_]+):[-?+]`)
	goEnvRead    = regexp.MustCompile(`os\.Getenv\("((?:YOUTUBE|YTT)_[A-Z_]+)"\)`)
	// A README row's first cell, e.g. "| `YOUTUBE_INGEST_ROOT` | ..." or
	// "| `A`, `B` | ...". Each backticked token is one documented variable.
	readmeRow  = regexp.MustCompile(`(?m)^\|([^|]*)\|`)
	readmeName = regexp.MustCompile("`((?:YOUTUBE|YTT)_[A-Z_]+)`")
)

func TestReadmeDocumentsEveryEnvVarTheCodeReads(t *testing.T) {
	read := map[string][]string{} // variable -> files that read it
	note := func(name, file string) { read[name] = append(read[name], file) }

	scripts, err := filepath.Glob(filepath.Join("scripts", "playlist-ingest", "*.sh"))
	if err != nil || len(scripts) == 0 {
		t.Fatalf("no ingest scripts found: %v", err)
	}
	for _, path := range scripts {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range shellEnvRead.FindAllStringSubmatch(string(body), -1) {
			note(m[1], path)
		}
	}
	goFiles, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range goFiles {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range goEnvRead.FindAllStringSubmatch(string(body), -1) {
			note(m[1], path)
		}
	}
	if len(read) == 0 {
		t.Fatal("found no env reads; the patterns no longer match the sources")
	}

	readme, err := os.ReadFile("README.md")
	if err != nil {
		t.Fatal(err)
	}
	documented := map[string]bool{}
	for _, row := range readmeRow.FindAllStringSubmatch(string(readme), -1) {
		for _, m := range readmeName.FindAllStringSubmatch(row[1], -1) {
			documented[m[1]] = true
		}
	}

	names := make([]string, 0, len(read))
	for name := range read {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if !documented[name] {
			t.Errorf("%s is read by %s but has no row in the README configuration table",
				name, strings.Join(read[name], ", "))
		}
	}
}
