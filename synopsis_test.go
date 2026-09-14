// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/marcelocantos/claudia"
)

func TestParseSynopsisReplySlugThenBody(t *testing.T) {
	slug, body, err := parseSynopsisReply("agent-memory.md\n\n# Title\n\n**TL;DR**: A claim.\n")
	if err != nil {
		t.Fatal(err)
	}
	if slug != "agent-memory.md" {
		t.Fatalf("slug = %q", slug)
	}
	if !strings.Contains(body, "**TL;DR**: A claim.") {
		t.Fatalf("body missing TL;DR: %q", body)
	}
}

func TestParseSynopsisReplyHeadingFallback(t *testing.T) {
	slug, _, err := parseSynopsisReply("# Hot Water Freezes Faster\n\n**TL;DR**: Mpemba.\n")
	if err != nil {
		t.Fatal(err)
	}
	if slug != "hot-water-freezes-faster.md" {
		t.Fatalf("slug = %q", slug)
	}
}

func TestParseSynopsisReplyRejectsMissingTLDR(t *testing.T) {
	_, _, err := parseSynopsisReply("topic.md\n\n# Title\n\nno tldr here\n")
	if err == nil {
		t.Fatal("expected error")
	}
}

func testPick(provider, model string) claudia.ModelPick {
	return claudia.ModelPick{Provider: claudia.Provider(provider), Model: model}
}

func TestGenerateSynopsisRunsTheResolvedPickOnce(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	var tried []string
	runSynopsisProvider = func(_ context.Context, provider, model, _, _ string) (string, error) {
		tried = append(tried, provider+"/"+model)
		return "topic.md\n\n# T\n\n**TL;DR**: ok.\n", nil
	}
	var stderr bytes.Buffer
	slug, _, used, err := generateSynopsis(context.Background(), testPick("grok", "grok-4.5"), "p", t.TempDir(), &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if used != "grok/grok-4.5" || slug != "topic.md" {
		t.Fatalf("used=%s slug=%s tried=%v", used, slug, tried)
	}
	if len(tried) != 1 {
		t.Fatalf("tried %v, want just the Resolve pick", tried)
	}
}

func TestGenerateSynopsisCapacityIsCapacityError(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, provider, _, _, _ string) (string, error) {
		return "", &capacityError{Provider: provider, Msg: "monthly spend limit"}
	}
	var stderr bytes.Buffer
	_, _, _, err := generateSynopsis(context.Background(), testPick("claude", "claude-sonnet-5"), "p", t.TempDir(), &stderr)
	var cap *capacityError
	if !errors.As(err, &cap) {
		t.Fatalf("err = %v, want capacityError", err)
	}
}

func TestGenerateSynopsisDoesNotFallThrough(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	var tried []string
	runSynopsisProvider = func(_ context.Context, provider, _, _, _ string) (string, error) {
		tried = append(tried, provider)
		return "not a synopsis", nil
	}
	var stderr bytes.Buffer
	_, _, _, err := generateSynopsis(context.Background(), testPick("grok", "grok-4.5"), "p", t.TempDir(), &stderr)
	if err == nil {
		t.Fatal("expected unusable reply to fail the pick")
	}
	if len(tried) != 1 {
		t.Fatalf("tried %v; Claudia already picked, ytt must not walk a ladder", tried)
	}
	var cap *capacityError
	if errors.As(err, &cap) {
		t.Fatalf("unusable reply must not be capacityError: %v", err)
	}
}

func TestGenerateSynopsisNonCapacityFailureIsNotCapacityError(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, _, _, _, _ string) (string, error) {
		return "", errors.New("empty result")
	}
	var stderr bytes.Buffer
	_, _, _, err := generateSynopsis(context.Background(), testPick("claude", "claude-sonnet-5"), "p", t.TempDir(), &stderr)
	if err == nil {
		t.Fatal("expected error")
	}
	var cap *capacityError
	if errors.As(err, &cap) {
		t.Fatalf("non-capacity failure must not be capacityError: %v", err)
	}
}

func TestCmdSynopsisWritesFile(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, _, _, _, _ string) (string, error) {
		return "from-test.md\n\n# Title\n\n**TL;DR**: written by test.\n", nil
	}
	dir := t.TempDir()
	contract := filepath.Join(dir, "contract.md")
	if err := os.WriteFile(contract, []byte("contract"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("YOUTUBE_SYNOPSIS_CONTRACT", contract)
	origRes := resolveSynopsis
	t.Cleanup(func() { resolveSynopsis = origRes })
	resolveSynopsis = func(_ context.Context, _ claudia.ModelPredicates) (claudia.ModelPick, error) {
		return testPick("grok", "grok-4.5"), nil
	}

	var out, errb bytes.Buffer
	code := cmdSynopsis([]string{
		"--dir", dir,
		"--title", "A Video",
		"--url", "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		"--providers", "grok",
	}, &out, &errb)
	if code != 0 {
		t.Fatalf("exit %d stderr=%s", code, errb.String())
	}
	got, err := os.ReadFile(filepath.Join(dir, "from-test.md"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "**TL;DR**: written by test.") {
		t.Fatalf("wrote %q", got)
	}
	if strings.TrimSpace(out.String()) != "from-test.md" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestCmdSynopsisCapacityExit255(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, provider, _, _, _ string) (string, error) {
		return "", &capacityError{Provider: provider, Msg: "usage limit"}
	}
	dir := t.TempDir()
	contract := filepath.Join(dir, "contract.md")
	if err := os.WriteFile(contract, []byte("contract"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("YOUTUBE_SYNOPSIS_CONTRACT", contract)
	origRes := resolveSynopsis
	t.Cleanup(func() { resolveSynopsis = origRes })
	resolveSynopsis = func(_ context.Context, _ claudia.ModelPredicates) (claudia.ModelPick, error) {
		return testPick("claude", "claude-sonnet-5"), nil
	}
	var out, errb bytes.Buffer
	code := cmdSynopsis([]string{
		"--dir", dir, "--title", "T", "--url", "https://youtu.be/dQw4w9WgXcQ",
	}, &out, &errb)
	if code != 255 {
		t.Fatalf("exit %d, want 255 stderr=%s", code, errb.String())
	}
}

func TestCmdSynopsisUnusableReplyExit1(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, _, _, _, _ string) (string, error) {
		return "I'll read the transcript first.\n\nnot a slug", nil
	}
	dir := t.TempDir()
	contract := filepath.Join(dir, "contract.md")
	if err := os.WriteFile(contract, []byte("contract"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("YOUTUBE_SYNOPSIS_CONTRACT", contract)
	origRes := resolveSynopsis
	t.Cleanup(func() { resolveSynopsis = origRes })
	resolveSynopsis = func(_ context.Context, _ claudia.ModelPredicates) (claudia.ModelPick, error) {
		return testPick("grok", "grok-4.5"), nil
	}
	var out, errb bytes.Buffer
	code := cmdSynopsis([]string{
		"--dir", dir, "--title", "T", "--url", "https://youtu.be/dQw4w9WgXcQ",
	}, &out, &errb)
	if code != 1 {
		t.Fatalf("exit %d, want 1 (per-video fail, not 255 queue abort) stderr=%s", code, errb.String())
	}
}

func TestCmdSynopsisResolveExhaustedExit255(t *testing.T) {
	dir := t.TempDir()
	contract := filepath.Join(dir, "contract.md")
	if err := os.WriteFile(contract, []byte("contract"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("YOUTUBE_SYNOPSIS_CONTRACT", contract)
	origRes := resolveSynopsis
	t.Cleanup(func() { resolveSynopsis = origRes })
	resolveSynopsis = func(_ context.Context, _ claudia.ModelPredicates) (claudia.ModelPick, error) {
		return claudia.ModelPick{}, errors.New("resolve: no catalog model matches predicates")
	}
	var out, errb bytes.Buffer
	code := cmdSynopsis([]string{
		"--dir", dir, "--title", "T", "--url", "https://youtu.be/dQw4w9WgXcQ",
	}, &out, &errb)
	if code != 255 {
		t.Fatalf("exit %d, want 255 stderr=%s", code, errb.String())
	}
}

func TestResolveSynopsisPickDefaultPrefersGrok(t *testing.T) {
	t.Setenv("YOUTUBE_INGEST_SYNOPSIS_PROVIDERS", "")
	origRes := resolveSynopsis
	origLoad := loadSynopsisPlanUsage
	t.Cleanup(func() {
		resolveSynopsis = origRes
		loadSynopsisPlanUsage = origLoad
	})
	loadSynopsisPlanUsage = func(context.Context) ([]claudia.PlanUsage, error) {
		return []claudia.PlanUsage{}, nil
	}
	resolveSynopsis = defaultResolveSynopsis
	got, err := resolveSynopsisPick(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if got.Provider != claudia.ProviderGrok {
		t.Fatalf("unpublished usage must prefer Grok, got %s/%s", got.Provider, got.Model)
	}
}

func TestResolveSynopsisPickSkipsHotGrok(t *testing.T) {
	t.Setenv("YOUTUBE_INGEST_SYNOPSIS_PROVIDERS", "")
	origRes := resolveSynopsis
	origLoad := loadSynopsisPlanUsage
	t.Cleanup(func() {
		resolveSynopsis = origRes
		loadSynopsisPlanUsage = origLoad
	})
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	week := now.Add(3*24*time.Hour + 12*time.Hour)
	pct := func(v float64) *float64 { return &v }
	loadSynopsisPlanUsage = func(context.Context) ([]claudia.PlanUsage, error) {
		return []claudia.PlanUsage{
			{
				Provider: claudia.ProviderGrok,
				Status:   claudia.PlanUsageAvailable,
				Windows: []claudia.PlanWindow{{
					Name:             claudia.PlanWindowWeekly,
					RemainingPercent: pct(20),
					UsedPercent:      pct(80),
					ResetsAt:         &week,
					LimitWindow:      7 * 24 * time.Hour,
				}},
			},
			{Provider: claudia.ProviderClaude, Status: claudia.PlanUsageUnavailable, Reason: "unpublished"},
			{Provider: claudia.ProviderCodex, Status: claudia.PlanUsageUnavailable, Reason: "unpublished"},
		}, nil
	}
	resolveSynopsis = func(ctx context.Context, pred claudia.ModelPredicates) (claudia.ModelPick, error) {
		pred.Now = now
		return defaultResolveSynopsis(ctx, pred)
	}
	got, err := resolveSynopsisPick(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if got.Provider == claudia.ProviderGrok {
		t.Fatalf("hot Grok must not be picked, got %s/%s", got.Provider, got.Model)
	}
	if got.Provider != claudia.ProviderClaude {
		t.Fatalf("want claude after hot grok, got %s/%s", got.Provider, got.Model)
	}
}

func TestResolveSynopsisPickAllowlistIsNotALadder(t *testing.T) {
	t.Setenv("YOUTUBE_INGEST_SYNOPSIS_PROVIDERS", "")
	origRes := resolveSynopsis
	origLoad := loadSynopsisPlanUsage
	t.Cleanup(func() {
		resolveSynopsis = origRes
		loadSynopsisPlanUsage = origLoad
	})
	loadSynopsisPlanUsage = func(context.Context) ([]claudia.PlanUsage, error) {
		return []claudia.PlanUsage{}, nil
	}
	var seen claudia.ModelPredicates
	resolveSynopsis = func(_ context.Context, pred claudia.ModelPredicates) (claudia.ModelPick, error) {
		seen = pred
		return testPick("claude", "claude-sonnet-5"), nil
	}
	got, err := resolveSynopsisPick(context.Background(), "claude,codex")
	if err != nil {
		t.Fatal(err)
	}
	if got.Provider != claudia.ProviderClaude {
		t.Fatalf("got %s", got.Provider)
	}
	if seen.PreferProvider != claudia.ProviderClaude {
		t.Fatalf("PreferProvider = %s", seen.PreferProvider)
	}
	excluded := map[claudia.Provider]bool{}
	for _, p := range seen.ExcludeProviders {
		excluded[p] = true
	}
	if !excluded[claudia.ProviderGrok] || !excluded[claudia.ProviderCursor] {
		t.Fatalf("allowlist must exclude grok and cursor, got %v", seen.ExcludeProviders)
	}
	if excluded[claudia.ProviderClaude] || excluded[claudia.ProviderCodex] {
		t.Fatalf("allowlist leaked into ExcludeProviders: %v", seen.ExcludeProviders)
	}
}
