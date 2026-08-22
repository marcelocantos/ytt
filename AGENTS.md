# ytt

Go CLI that fetches YouTube transcripts via yt-dlp and drives a bulk
ingest pipeline. `ytt ingest` execs bundled bash under
`scripts/playlist-ingest/`; `ytt synopsis` talks to Claudia
(grok → claude → codex); `ytt build-index` rewrites the knowledge-base
table. There is no Python package and no `claude -p` path.

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

## Delivery

Merged to default branch (`master`). Ship only when asked (`/push`,
“open a PR”, “release”).
