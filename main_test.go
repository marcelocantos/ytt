// Copyright 2026 Marcelo Cantos
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"testing"
)

// TestMain keeps the hermetic suite off a claudia daemon installed on the
// machine: with one reachable, a synopsis Task in a test would run for real
// on the daemon.
func TestMain(m *testing.M) {
	if os.Getenv("CLAUDIA_NO_BROKER") == "" {
		_ = os.Setenv("CLAUDIA_NO_BROKER", "1")
	}
	os.Exit(m.Run())
}
