# Stability

ytt is pre-1.0. This document tracks the project's readiness for a 1.0
release — the point at which backwards compatibility becomes a binding
commitment.

## Stability commitment

Once 1.0 ships, breaking changes to the public CLI surface, the
playlist-ingest workflow's env-var contract, or the on-disk knowledge-
base layout require a major version bump. The pre-1.0 period exists to
get those right.

## Interaction surface

Snapshot of this tree (`main.version` is 0.11.0; unreleased commits
after the `v0.11.0` tag are included). ytt is a Go CLI
(`github.com/marcelocantos/ytt`). `ytt ingest` execs the bundled bash
workflow under `scripts/playlist-ingest/`. There is no Python package,
pipx install path, or `claude -p` synopsis step.

### CLI — `ytt` (transcript)

| Form | Stability |
|---|---|
| `ytt <video>...` (positional video IDs/URLs) | Stable |
| `ytt -t <video>` / `ytt --timestamps <video>` | Stable |
| `ytt -j <video>` / `ytt --json <video>` | Stable |
| `ytt --version` | Stable |
| `ytt --help` | Stable |
| `ytt --help-agent` | Stable |

Accepted input forms (stable): raw 11-char video ID,
`https://www.youtube.com/watch?v=…`, `https://youtu.be/…`,
`https://youtube.com/shorts/…`, `…/embed/…`.

Output contract (stable):
- Plain mode: transcript joined with single spaces on stdout.
- `-t` mode: one segment per line, prefixed with `[mm:ss]` or
  `[h:mm:ss]` for videos ≥ 1 hour.
- `--json` mode: one compact JSON object per video on its own line
  (JSONL for multi-video). Object shape: `video_id`, `language`,
  `language_code`, `is_generated`, `snippets:
  [{text, start, duration}, ...]`. The shape is the public contract;
  new top-level fields may be added without a major bump (consumers
  must ignore unknown keys). Seconds render with a trailing `.0` on
  integral values so existing JSON consumers keep matching.
- `-t` and `--json` are mutually exclusive.
- Errors on stderr, one line per failure, `ytt: <video-id>: <reason>`.
- Exit codes `0` (all ok), `1` (≥1 video failed), `2` (usage error).

### CLI — `ytt ingest` (subcommand)

| Form | Stability |
|---|---|
| `ytt ingest [PLAYLIST_URL]` | Needs review |
| `ytt ingest --download` | Needs review |
| `ytt ingest --analyze` | Needs review |
| `ytt ingest --dry-run` | Needs review |

Behaviour: passes through to the bundled
`scripts/playlist-ingest/ingest.sh`, with all remaining args forwarded
verbatim. Default (neither `--download` nor `--analyze`) is two
fan-outs: paced download, then unthrottled analyze. Subcommand surface
is fluid until the underlying scripts settle (see **Playlist-ingest
workflow** below).

### CLI — `ytt build-index` / `ytt synopsis`

| Form | Stability |
|---|---|
| `ytt build-index` | Needs review |
| `ytt synopsis --dir DIR --title TITLE --url URL` | Needs review |

`build-index` rewrites `$YOUTUBE_INGEST_ROOT/youtube-knowledge-base.md`
from on-disk synopses. `synopsis` runs a Claudia Task ladder (default
`grok,claude,codex`, overridable with `--providers` or
`YOUTUBE_INGEST_SYNOPSIS_PROVIDERS`) and writes `<slug>.md` into
`--dir`. Format of that file is defined only in
`scripts/playlist-ingest/synopsis-contract.md`.

### Playlist-ingest workflow — env vars

| Variable | Default | Stability |
|---|---|---|
| `YOUTUBE_INGEST_PLAYLIST` | (required if not passed positionally) | Needs review |
| `YOUTUBE_INGEST_ROOT` | `~/think/knowledge/youtube` | Needs review |
| `YOUTUBE_CHANNELS_FILE` | `$XDG_CONFIG_HOME/ytt/channels.yaml` | Needs review |
| `YOUTUBE_INGEST_STALE_DAYS` | `7` | Needs review |
| `YOUTUBE_INGEST_STATE_DIR` | `$XDG_STATE_HOME/ytt` | Needs review |
| `YOUTUBE_INGEST_QUEUE` | `$YOUTUBE_INGEST_STATE_DIR/backfill.ids` | Needs review |
| `YOUTUBE_INGEST_BLURTER_BIN` | `blurter` (PATH) | Needs review |
| `YOUTUBE_INGEST_CONCURRENCY` | `4` | Stable |
| `YOUTUBE_INGEST_ANALYZE_CONCURRENCY` | same as download | Needs review |
| `YOUTUBE_INGEST_DOWNLOAD_BATCH` | `16` | Needs review |
| `YOUTUBE_INGEST_ORPHAN_MIN` | `60` | Needs review |
| `YOUTUBE_INGEST_YTT_BIN` | `ytt` (PATH) | Stable |
| `YOUTUBE_INGEST_SYNOPSIS_PROVIDERS` | `grok,claude,codex` | Needs review |

The default `YOUTUBE_INGEST_ROOT` of `~/think/knowledge/youtube` is
personal-vault-shaped and likely to move to something neutral
(e.g. `~/ytt-knowledge`) before 1.0.

### Playlist-ingest workflow — on-disk layout

| Path | Stability |
|---|---|
| `$ROOT/<video-id>/.transcript/transcript.json` (yt-dlp payload, pretty-printed) | Needs review |
| `$ROOT/<video-id>/meta.json` (yt-dlp JSON shape) | Needs review |
| `$ROOT/<video-id>/<slug>.md` (synopsis) | Fluid |
| `$ROOT/.processed` (one ID per line) | Stable |
| `$ROOT/.download-failed` (undownloadable IDs, skipped later) | Needs review |
| `$ROOT/.channels/<handle>` (cursor file) | Stable |
| `$ROOT/.ingest.log` | Stable |
| `$XDG_STATE_HOME/ytt/last-ingest` (liveness stamp, unix seconds) | Needs review |
| `$ROOT/youtube-knowledge-base.md` (index) | Fluid |

The synopsis file's filename convention (topic slug) and TL;DR-line
contract are specified in `synopsis-contract.md`. The index is a
two-column markdown table (title / TL;DR, newest first); the layout
has changed once (v0.5.0) and may change again.

### Channel config schema (`channels.yaml`)

```yaml
channels:
  - handle: <youtube-handle>          # required, with or without leading "@"
    name: <display-name>              # optional, cosmetic
```

A 24-character `UC…` channel id is also accepted as `handle` and is
fetched via `/channel/UC…/videos` (so a Takeout dump does not need a
handle-resolution pass).

Stability: Needs review. The handle/name pair is the minimum viable
schema; per-channel options (filters, ingest cadence, alternative
URLs) are likely to land before 1.0.

### Distribution

| Channel | Stability |
|---|---|
| Homebrew formula `marcelocantos/tap/ytt` | Stable |
| GitHub release tarballs (`darwin-arm64`, `linux-amd64`, `linux-arm64`) — static binary plus bundled `scripts/` | Stable |
| `go install` (binary only; no ingest/synopsis scripts) | Out of scope as a full install |
| pipx / PyPI / a Python package | Out of scope (retired) |

## Gaps and prerequisites for 1.0

- **Knowledge-base index format**: the two-column layout shipped in
  v0.5.0 is the second iteration. Settle on a final schema before
  locking in. Parser tests exist (`index_test.go`,
  `build-index.bats`); the remaining work is the schema, not coverage.
- **`YOUTUBE_INGEST_ROOT` default**: change from `~/think/knowledge/youtube`
  to a neutral default before 1.0.
- **Network-independent transcript parse test**: CLI and JSON rendering
  are tested against stubs. There is still no canned yt-dlp json3
  fixture for the caption-event parser, so json3 shape drift is only
  caught in production.
- **Provider CLIs for synopses**: `ytt synopsis` talks to Claudia;
  grok/claude/codex binaries are a runtime dependency of analyze, not
  of the Go module. Document which of the ladder must be present for
  a scheduled run.

## Out of scope for 1.0

- A `ytt ingest <video-id>` single-video subcommand (the
  `ingest-one.sh` script covers this for now and isn't worth surfacing
  as a first-class subcommand).
- Live, watched-folder ingest (current model is one-shot per
  invocation).
- A built-in model. Synopses always go through Claudia providers.
- Obsidian-specific schema additions (frontmatter tags, dataview
  hints). The on-disk layout stays markdown-with-conventions.
