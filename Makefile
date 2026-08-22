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
	@test -z "$$(git status --porcelain)" && echo "✓ clean tree" || \
		(echo "✗ dirty tree"; git status --short; exit 1)

clean:
	rm -f ytt
