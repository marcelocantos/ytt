// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/marcelocantos/claudia"
)

func TestSynopsisSessionProvidersLive(t *testing.T) {
	if os.Getenv("YTT_LIVE") != "1" {
		t.Skip("YTT_LIVE=1 requires the live host broker")
	}
	for _, provider := range []claudia.Provider{claudia.ProviderClaude, claudia.ProviderCodex, claudia.ProviderGrok, claudia.ProviderCursor} {
		t.Run(string(provider), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), synopsisProviderTimeout)
			defer cancel()
			usage, err := defaultLoadSynopsisPlanUsage(ctx)
			if err != nil {
				t.Fatal(err)
			}
			pick, err := claudia.Resolve(ctx, claudia.ModelPredicates{
				Mode: claudia.CapabilitySession, Quality: claudia.ModelQualityStandard,
				PreferPlan: true, Background: true, RequireUsage: true, Usage: usage,
				ExcludeProviders: providersNotIn([]claudia.Provider{provider}),
			})
			if err != nil {
				t.Fatalf("OUTAGE: no admitted background capacity on %s: %v", provider, err)
			}
			if pick.Provider != provider {
				t.Fatalf("strict provider resolved to %s", pick.Provider)
			}
			reply, err := runClaudiaProvider(ctx, string(pick.Provider), pick.Model, "Reply with exactly YTT_SESSION_OK. Do not use any tools.", t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(reply, "YTT_SESSION_OK") {
				t.Fatalf("unexpected response: %q", reply)
			}
		})
	}
}

// The shipped CLI must turn a synthetic downloaded transcript into a synopsis,
// .processed row and index through the host broker. All content and alert
// state are isolated; it never submits a test notification to the owner.
func TestIngestSynopsisJourneyLive(t *testing.T) {
	if os.Getenv("YTT_LIVE") != "1" {
		t.Skip("YTT_LIVE=1 requires the live host broker")
	}
	source := mustAbsolute(t, filepath.Join("testdata", "journey", "YTTJOURNEY0"))
	id := filepath.Base(source)
	if len(id) != 11 {
		t.Fatal("journey source must be a YouTube video directory")
	}
	root := t.TempDir()
	video := filepath.Join(root, "youtube", id)
	if err := os.MkdirAll(filepath.Join(video, ".transcript"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"meta.json", ".transcript/transcript.json"} {
		data, err := os.ReadFile(filepath.Join(source, rel))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(video, rel), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	notifier := filepath.Join(root, "no-notify")
	if err := os.WriteFile(notifier, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	channels := filepath.Join(root, "channels.yaml")
	if err := os.WriteFile(channels, []byte("channels: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "./ytt", "ingest", "--analyze")
	cmd.Env = append(os.Environ(),
		"YOUTUBE_INGEST_ROOT="+filepath.Dir(video), "YOUTUBE_INGEST_STATE_DIR="+filepath.Join(root, "state"),
		"YOUTUBE_INGEST_YTT_BIN="+mustAbsolute(t, "ytt"), "YOUTUBE_INGEST_LOG="+filepath.Join(root, "ingest.log"),
		"YOUTUBE_CHANNELS_FILE="+channels, "YOUTUBE_INGEST_BLURTER_BIN="+notifier,
		"YOUTUBE_INGEST_REQUIRE_DAEMON=1", "YOUTUBE_INGEST_ANALYZE_CONCURRENCY=1", "YOUTUBE_INDEX_RECENT_DAYS=0")
	output, err := cmd.CombinedOutput()
	if err != nil {
		log, _ := os.ReadFile(filepath.Join(root, "ingest.log"))
		t.Fatalf("ingest failed: %v\n%s\n%s", err, output, log)
	}
	processed, err := os.ReadFile(filepath.Join(filepath.Dir(video), ".processed"))
	if err != nil || !strings.Contains(string(processed), id) {
		t.Fatalf("video was not processed: %s, %v\n%s", processed, err, output)
	}
	files, err := filepath.Glob(filepath.Join(video, "*.md"))
	if err != nil || len(files) != 1 {
		t.Fatalf("expected one synopsis, got %v, %v", files, err)
	}
	body, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := parseSynopsisReply(filepath.Base(files[0]) + "\n\n" + string(body)); err != nil {
		t.Fatal(err)
	}
	index, err := os.ReadFile(filepath.Join(filepath.Dir(video), "youtube-knowledge-base.md"))
	if err != nil || !strings.Contains(string(index), id) {
		t.Fatalf("index did not include video: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(video, "meta.json"))
	if err != nil || !json.Valid(data) {
		t.Fatal("journey damaged metadata")
	}
}

func mustAbsolute(t *testing.T, path string) string {
	t.Helper()
	abs, err := filepath.Abs(path)
	if err != nil {
		t.Fatal(err)
	}
	return abs
}
