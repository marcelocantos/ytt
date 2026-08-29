# Local build and test. Never pass -j; set MAKEFLAGS here if a project needs it.
#
# Parent ~/work/github.com/marcelocantos/go.work does not list this module, so
# a bare `go test ./...` fails here with "directory prefix . does not contain
# modules listed in go.work". CI has no parent workspace and is fine either
# way; pin GOWORK off so `make test` is an oracle on this machine too.
export GOWORK := off
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.version=$(patsubst v%,%,$(VERSION))

.PHONY: all build test test-go test-scripts vet lint bullseye clean

all: vet test build

build:
	go build -trimpath -ldflags "$(LDFLAGS)" -o ytt .

# Full local suite: Go unit tests plus the bats shell tests that still cover
# the ingest pipeline.
test: test-go test-scripts

test-go:
	go test ./... -count=1 -race

# Depends on build: parts of the pipeline are Go subcommands, and a stale
# binary would silently test the wrong thing.
test-scripts: build
	bats scripts/playlist-ingest/tests/

vet:
	go vet ./...

lint:
	@test -z "$$(gofmt -l .)" || { echo "gofmt needed:"; gofmt -l .; exit 1; }

bullseye: vet lint
	@go build -o /dev/null . && echo "✓ builds"
	@for f in scripts/playlist-ingest/*.sh; do /bin/bash -n "$$f" || exit 1; done; \
		echo "✓ syntax, incl. macOS /bin/bash 3.2"
	@dirty=$$(git status --porcelain | grep -vE 'bullseye\.yaml$$' || true); \
	if [ -z "$$dirty" ]; then echo "✓ working tree clean"; \
	else \
	  echo ""; \
	  echo "================================================================"; \
	  echo "⚠  DIRTY WORKING TREE"; \
	  echo ""; \
	  echo "Warning only — invariants still pass (exit 0)."; \
	  echo "Look at the files below before starting a new target."; \
	  echo "Leftover work from a different objective → park it in a commit first."; \
	  echo "This session's WIP on the recommended target → continue."; \
	  echo "================================================================"; \
	  echo "$$dirty"; \
	  echo "================================================================"; \
	  echo ""; \
	fi

clean:
	rm -f ytt
