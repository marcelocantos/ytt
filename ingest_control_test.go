// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDownloadBackoffIsSharedAndResetsOnlyAfterRecovery(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			state, err := controlDownload(dir, "download-failure", strings.NewReader("HTTP Error 429: Too Many Requests"), now)
			if err != nil {
				t.Error(err)
				return
			}
			if state.Delay != downloadBackoffInitial || !state.Until.Equal(now.Add(downloadBackoffInitial)) {
				t.Errorf("concurrent state: %+v", state)
			}
		})
	}
	wg.Wait()
	state, err := controlDownload(dir, "download-succeeded", nil, now.Add(time.Minute))
	if err != nil || state.Delay != downloadBackoffInitial {
		t.Fatalf("in-flight success erased cooldown: %+v, %v", state, err)
	}
	for _, delay := range []time.Duration{12 * time.Hour, 24 * time.Hour, 24 * time.Hour} {
		now = state.Until.Add(time.Second)
		state, err = controlDownload(dir, "download-failure", strings.NewReader("HTTP Error 429"), now)
		if err != nil || state.Delay != delay {
			t.Fatalf("next cooldown: %+v, %v, want %s", state, err, delay)
		}
	}
	now = state.Until.Add(time.Second)
	state, err = controlDownload(dir, "download-succeeded", nil, now)
	if err != nil || !state.Until.IsZero() {
		t.Fatalf("success failed to reset cooldown: %+v, %v", state, err)
	}
	state, err = controlDownload(dir, "download-failure", strings.NewReader("connection reset by peer"), now)
	if err != nil || !state.Until.IsZero() {
		t.Fatalf("unrelated failure deferred: %+v, %v", state, err)
	}
}
