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

func TestGenerateSynopsisFirstProviderWins(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	var tried []string
	runSynopsisProvider = func(_ context.Context, provider, _, _ string) (string, error) {
		tried = append(tried, provider)
		return "topic.md\n\n# T\n\n**TL;DR**: ok.\n", nil
	}
	var stderr bytes.Buffer
	slug, _, used, err := generateSynopsis(context.Background(), []string{"grok", "claude"}, "p", t.TempDir(), &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if used != "grok" || slug != "topic.md" {
		t.Fatalf("used=%s slug=%s tried=%v", used, slug, tried)
	}
	if len(tried) != 1 {
		t.Fatalf("tried %v, want just grok", tried)
	}
}

func TestGenerateSynopsisFallsThroughCapacity(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, provider, _, _ string) (string, error) {
		if provider == "grok" {
			return "", &capacityError{Provider: "grok", Msg: "rate limit"}
		}
		return "from-claude.md\n\n# T\n\n**TL;DR**: via claude.\n", nil
	}
	var stderr bytes.Buffer
	_, _, used, err := generateSynopsis(context.Background(), []string{"grok", "claude"}, "p", t.TempDir(), &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if used != "claude" {
		t.Fatalf("used = %s, want claude", used)
	}
}

func TestGenerateSynopsisAllCapacityIs255Shape(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, provider, _, _ string) (string, error) {
		return "", &capacityError{Provider: provider, Msg: "monthly spend limit"}
	}
	var stderr bytes.Buffer
	_, _, _, err := generateSynopsis(context.Background(), []string{"grok", "claude", "codex"}, "p", t.TempDir(), &stderr)
	var cap *capacityError
	if !errors.As(err, &cap) {
		t.Fatalf("err = %v, want capacityError", err)
	}
}

func TestGenerateSynopsisSkipsMissingThenFailsNonCapacity(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, provider, _, _ string) (string, error) {
		switch provider {
		case "grok":
			return "", errors.New("executable file not found in $PATH")
		case "claude":
			return "", errors.New("model hallucinated a tool")
		default:
			return "", errors.New("not reached")
		}
	}
	var stderr bytes.Buffer
	_, _, _, err := generateSynopsis(context.Background(), []string{"grok", "claude"}, "p", t.TempDir(), &stderr)
	if err == nil {
		t.Fatal("expected error")
	}
	var cap *capacityError
	if errors.As(err, &cap) {
		t.Fatalf("non-capacity failure must not be capacityError: %v", err)
	}
}

func TestGenerateSynopsisEmptyReplyTriesNext(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, provider, _, _ string) (string, error) {
		if provider == "grok" {
			return "not a synopsis", nil
		}
		return "ok.md\n\n# T\n\n**TL;DR**: recovered.\n", nil
	}
	var stderr bytes.Buffer
	_, _, used, err := generateSynopsis(context.Background(), []string{"grok", "claude"}, "p", t.TempDir(), &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if used != "claude" {
		t.Fatalf("used = %s", used)
	}
}

func TestCmdSynopsisWritesFile(t *testing.T) {
	restore := runSynopsisProvider
	t.Cleanup(func() { runSynopsisProvider = restore })
	runSynopsisProvider = func(_ context.Context, _, _, _ string) (string, error) {
		return "from-test.md\n\n# Title\n\n**TL;DR**: written by test.\n", nil
	}
	dir := t.TempDir()
	contract := filepath.Join(dir, "contract.md")
	if err := os.WriteFile(contract, []byte("contract"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("YOUTUBE_SYNOPSIS_CONTRACT", contract)

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
	runSynopsisProvider = func(_ context.Context, provider, _, _ string) (string, error) {
		return "", &capacityError{Provider: provider, Msg: "usage limit"}
	}
	dir := t.TempDir()
	contract := filepath.Join(dir, "contract.md")
	if err := os.WriteFile(contract, []byte("contract"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("YOUTUBE_SYNOPSIS_CONTRACT", contract)
	var out, errb bytes.Buffer
	code := cmdSynopsis([]string{
		"--dir", dir, "--title", "T", "--url", "https://youtu.be/dQw4w9WgXcQ",
		"--providers", "grok,claude",
	}, &out, &errb)
	if code != 255 {
		t.Fatalf("exit %d, want 255 stderr=%s", code, errb.String())
	}
}

func TestParseProviderLadderDefault(t *testing.T) {
	t.Setenv("YOUTUBE_INGEST_SYNOPSIS_PROVIDERS", "")
	got := parseProviderLadder("")
	want := []string{"grok", "claude", "codex"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got %v", got)
	}
}
