# ytt

Go CLI that fetches YouTube transcripts via yt-dlp and drives a bulk
ingest pipeline. `ytt ingest` execs bundled bash under
`scripts/playlist-ingest/`; `ytt synopsis` talks to Jevons's broker
(Claudia Resolve still picks one model); `ytt build-index` rewrites the knowledge-base
table. There is no Python package and no `claude -p` path. Scheduled
analyze requires `jevons-broker status`, not Homebrew `claudia`.

Consumer CLI contract: [`agents-guide.md`](agents-guide.md) (also
embedded as `ytt --help-agent`). Synopsis file format:
[`scripts/playlist-ingest/synopsis-contract.md`](scripts/playlist-ingest/synopsis-contract.md)
— edit the format only there.

## Layout

- `main.go`, `transcript.go`, `index.go`, `synopsis.go` — `package main`
- `scripts/playlist-ingest/` — ingest orchestration, bats, launchd, contract
- Release tarballs ship the binary plus `scripts/`; Homebrew moves that
  tree into `libexec`

## Build and test

A parent `go.work` at `~/work/github.com/marcelocantos/go.work` does
not list this module. Bare `go test` / `make test-go` fail with
"directory prefix . does not contain modules listed in go.work" unless
`GOWORK` is off:

```bash
export GOWORK=off
make test          # go test ./... -race, then bats
# or
GOWORK=off go test ./... -count=1 -race
bats scripts/playlist-ingest/tests/
```

Go 1.26. CI also runs bats under macOS `/bin/bash` 3.2. Do not add
bash-4 constructs (`mapfile`, associative arrays) to the ingest
scripts.

## Conventions

- Go: `~/.claude/go.md` (no functional-options APIs).
- Bash: `~/.claude/bash.md` before extending `scripts/*.sh`.
- Do not rewrite `ingest.sh` in one shot; extract stateful slices
  with bats staying green.

## Homebrew

The formula in `marcelocantos/homebrew-tap` is published by
[tapper](https://github.com/marcelocantos/tapper) from the dev Mac, not by CI.
After a release's assets have uploaded (`.github/workflows/release.yml`), run
`make release-tap TAG=vX.Y.Z` (or `tapper push --version vX.Y.Z`). Config lives in `tapper.yaml`;
the tap token is read from the macOS keychain, so no Actions secret is needed.
Docker must be running.

## Delivery

Merged to default branch (`master`). Ship only when asked (`/push`,
“open a PR”, “release”).
