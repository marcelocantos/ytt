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

func TestFormatSynopsisPickIncludesEffort(t *testing.T) {
	if got := formatSynopsisPick(testPick("grok", "grok-4.6")); got != "grok/grok-4.6" {
		t.Fatalf("no effort: %s", got)
	}
	got := formatSynopsisPick(claudia.ModelPick{
		Provider: claudia.ProviderGrok, Model: "grok-4.6", Effort: claudia.ModelEffortHigh,
	})
	if got != "grok/grok-4.6/high" {
		t.Fatalf("with effort: %s", got)
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

// generalIntel is a hermetic purpose-quality series. Scores and research
// costs are arranged so grok-4.6/high is cheapest standard general, and
// sonnet/high is the next remaining pick after Grok is weekly-hot.
func generalIntel() *claudia.ModelIntelArgs {
	return &claudia.ModelIntelArgs{
		Latest: []claudia.ModelObservation{
			{Generation: "grok-4.6", Effort: claudia.ModelEffortHigh, Purpose: claudia.ModelPurposeAnalysis, Value: 80, CostUSD: 0.05},
			{Generation: "grok-4.5", Effort: claudia.ModelEffortHigh, Purpose: claudia.ModelPurposeAnalysis, Value: 62, CostUSD: 0.04},
			{Generation: "claude-sonnet-5", Effort: claudia.ModelEffortHigh, Purpose: claudia.ModelPurposeAnalysis, Value: 72, CostUSD: 0.10},
			{Generation: "claude-opus-5", Effort: claudia.ModelEffortHigh, Purpose: claudia.ModelPurposeAnalysis, Value: 90, CostUSD: 0.50},
			{Generation: "claude-haiku-4-5", Effort: claudia.ModelEffortUnspecified, Purpose: claudia.ModelPurposeAnalysis, Value: 35, CostUSD: 0.01},
			{Generation: "gpt-5-codex", Effort: claudia.ModelEffortHigh, Purpose: claudia.ModelPurposeAnalysis, Value: 68, CostUSD: 0.30},
			{Generation: "composer-2.5", Effort: claudia.ModelEffortUnspecified, Purpose: claudia.ModelPurposeAnalysis, Value: 58, CostUSD: 0.20},
			{Generation: "grok-4.6", Effort: claudia.ModelEffortHigh, Purpose: claudia.ModelPurposeGeneral, Value: 80, CostUSD: 0.05},
			{Generation: "claude-sonnet-5", Effort: claudia.ModelEffortHigh, Purpose: claudia.ModelPurposeGeneral, Value: 72, CostUSD: 0.10},
		},
	}
}

func withPurposeIntel(resolve func(context.Context, claudia.ModelPredicates) (claudia.ModelPick, error)) func(context.Context, claudia.ModelPredicates) (claudia.ModelPick, error) {
	return func(ctx context.Context, pred claudia.ModelPredicates) (claudia.ModelPick, error) {
		if pred.Intel == nil {
			pred.Intel = generalIntel()
		}
		return resolve(ctx, pred)
	}
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

func TestResolveSynopsisPickDefaultAsksForStandardQuality(t *testing.T) {
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
		return withPurposeIntel(defaultResolveSynopsis)(context.Background(), pred)
	}
	got, err := resolveSynopsisPick(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if seen.PreferProvider != "" {
		t.Fatalf("default must not name a vendor, PreferProvider=%s", seen.PreferProvider)
	}
	if seen.Purpose != claudia.ModelPurposeAnalysis {
		t.Fatalf("Purpose = %s, want analysis", seen.Purpose)
	}
	if seen.Quality != claudia.ModelQualityStandard {
		t.Fatalf("Quality = %s, want standard", seen.Quality)
	}
	if got.Quality != claudia.ModelQualityStandard {
		t.Fatalf("pick must be standard intelligence, got %s/%s (%s)", got.Provider, got.Model, got.Quality)
	}
	if got.Purpose != claudia.ModelPurposeAnalysis || got.Effort == "" {
		t.Fatalf("pick must carry purpose-quality outputs, got %+v", got)
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
		return withPurposeIntel(defaultResolveSynopsis)(ctx, pred)
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

func TestResolveSynopsisPickDefaultDoesNotExcludeCursor(t *testing.T) {
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
		return testPick("grok", "grok-4.5"), nil
	}
	if _, err := resolveSynopsisPick(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	if len(seen.ExcludeProviders) != 0 {
		t.Fatalf("default pick must not hard-exclude providers, got %v", seen.ExcludeProviders)
	}
	if seen.PreferProvider != "" || seen.Quality != claudia.ModelQualityStandard || seen.Purpose != claudia.ModelPurposeAnalysis {
		t.Fatalf("default predicates: prefer=%q quality=%s purpose=%s", seen.PreferProvider, seen.Quality, seen.Purpose)
	}
}

func TestResolveSynopsisPickFallsBackWithoutIntelSeries(t *testing.T) {
	t.Setenv("YOUTUBE_INGEST_SYNOPSIS_PROVIDERS", "")
	t.Setenv("CLAUDIA_MODEL_INTEL", t.TempDir())
	origRes := resolveSynopsis
	origLoad := loadSynopsisPlanUsage
	t.Cleanup(func() {
		resolveSynopsis = origRes
		loadSynopsisPlanUsage = origLoad
	})
	loadSynopsisPlanUsage = func(context.Context) ([]claudia.PlanUsage, error) {
		return []claudia.PlanUsage{}, nil
	}
	var purposes []claudia.ModelPurpose
	resolveSynopsis = func(_ context.Context, pred claudia.ModelPredicates) (claudia.ModelPick, error) {
		purposes = append(purposes, pred.Purpose)
		if pred.Purpose != "" {
			return claudia.ModelPick{}, errors.New("resolve: no catalog model matches predicates")
		}
		return testPick("claude", "claude-sonnet-5"), nil
	}
	got, err := resolveSynopsisPick(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(purposes) != 3 || purposes[0] != claudia.ModelPurposeAnalysis || purposes[1] != claudia.ModelPurposeGeneral || purposes[2] != "" {
		t.Fatalf("want analysis, general, then catalog, got %v", purposes)
	}
	if got.Provider != claudia.ProviderClaude {
		t.Fatalf("catalog fallback pick %s", got.Provider)
	}
}

func TestResolveSynopsisPickPropagatesPlanUsageError(t *testing.T) {
	t.Setenv("YOUTUBE_INGEST_SYNOPSIS_PROVIDERS", "")
	origRes := resolveSynopsis
	origLoad := loadSynopsisPlanUsage
	t.Cleanup(func() {
		resolveSynopsis = origRes
		loadSynopsisPlanUsage = origLoad
	})
	loadSynopsisPlanUsage = func(context.Context) ([]claudia.PlanUsage, error) {
		return nil, errors.New("claudia: broker protocol: unknown_field")
	}
	resolveSynopsis = func(context.Context, claudia.ModelPredicates) (claudia.ModelPick, error) {
		t.Fatal("Resolve must not run after a plan-usage error")
		return claudia.ModelPick{}, nil
	}
	_, err := resolveSynopsisPick(context.Background(), "")
	if err == nil || !strings.Contains(err.Error(), "unknown_field") {
		t.Fatalf("want broker error, got %v", err)
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
