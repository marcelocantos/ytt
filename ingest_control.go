// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"time"
)

const (
	ingestDeferred         = 75
	downloadBackoffInitial = 6 * time.Hour
	downloadBackoffMaximum = 24 * time.Hour
)

var youtubeRateLimit = regexp.MustCompile(`(?i)(HTTP (Error )?429\b|status( code)?[=: ]+429\b|too many requests)`)

type downloadBackoff struct {
	Until time.Time     `json:"until"`
	Delay time.Duration `json:"delay"`
}

// ingest-control owns the scripts' shared cooldown. A 429 pauses the source,
// not one video; workers and subsequent ticks consult the persisted deadline.
func cmdIngestControl(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "ytt ingest-control: expected download-ready, download-failure, or download-succeeded")
		return 2
	}
	dir := os.Getenv("YOUTUBE_INGEST_STATE_DIR")
	if dir == "" {
		base := os.Getenv("XDG_STATE_HOME")
		if base == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				fmt.Fprintln(stderr, err)
				return 1
			}
			base = filepath.Join(home, ".local", "state")
		}
		dir = filepath.Join(base, "ytt")
	}
	now := time.Now()
	state, err := controlDownload(dir, args[0], stdin, now)
	if err != nil {
		fmt.Fprintf(stderr, "ytt ingest-control: %v\n", err)
		return 1
	}
	if now.Before(state.Until) {
		fmt.Fprintf(stdout, "YouTube download deferred until %s after HTTP 429\n", state.Until.UTC().Format(time.RFC3339))
		return ingestDeferred
	}
	return 0
}

func controlDownload(dir, action string, input io.Reader, now time.Time) (downloadBackoff, error) {
	limited := false
	switch action {
	case "download-ready", "download-succeeded":
	case "download-failure":
		data, err := io.ReadAll(io.LimitReader(input, 1<<20))
		if err != nil {
			return downloadBackoff{}, err
		}
		limited = youtubeRateLimit.Match(data)
	default:
		return downloadBackoff{}, fmt.Errorf("unknown action %q", action)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return downloadBackoff{}, err
	}
	lock, err := os.OpenFile(filepath.Join(dir, "download-backoff.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return downloadBackoff{}, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return downloadBackoff{}, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	path := filepath.Join(dir, "download-backoff.json")
	var state downloadBackoff
	data, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(data, &state); err != nil {
			return state, fmt.Errorf("reading cooldown: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return state, err
	}
	// Another worker's 429 has already paused the source. Do not extend its
	// deadline or erase it on a success that was already in flight.
	if now.Before(state.Until) {
		return state, nil
	}
	if action == "download-succeeded" {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return state, err
		}
		return downloadBackoff{}, nil
	}
	if !limited {
		return state, nil
	}
	state.Delay *= 2
	if state.Delay < downloadBackoffInitial {
		state.Delay = downloadBackoffInitial
	}
	if state.Delay > downloadBackoffMaximum {
		state.Delay = downloadBackoffMaximum
	}
	state.Until = now.Add(state.Delay)
	data, err = json.Marshal(state)
	if err != nil {
		return state, err
	}
	tmp, err := os.CreateTemp(dir, ".download-backoff-*")
	if err != nil {
		return state, err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return state, err
	}
	if err := tmp.Close(); err != nil {
		return state, err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return state, err
	}
	return state, nil
}
