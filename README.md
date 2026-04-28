# ytt

Fetch YouTube video transcripts from the command line.

A thin wrapper around [`youtube-transcript-api`](https://github.com/jdepoix/youtube-transcript-api)
that extracts video IDs from URLs, handles multiple videos, and optionally
prefixes each segment with a timestamp.

## Install

### Homebrew (recommended)

```sh
brew install marcelocantos/tap/ytt
```

### From the GitHub release

Each release attaches standalone binaries for macOS arm64, Linux x86_64,
and Linux arm64. Download the tarball matching your platform from the
[releases page](https://github.com/marcelocantos/ytt/releases/latest),
extract, and put `ytt` on your PATH.

### From source

Requires Python 3.10+:

```sh
pipx install git+https://github.com/marcelocantos/ytt
```

## Usage

```sh
ytt dQw4w9WgXcQ                                  # raw video ID
ytt https://www.youtube.com/watch?v=dQw4w9WgXcQ  # full URL
ytt https://youtu.be/dQw4w9WgXcQ                 # short URL
ytt --timestamps dQw4w9WgXcQ                     # one line per segment, [mm:ss] prefix
ytt <id1> <id2> <id3>                            # multiple videos, blank line between
```

Plain output joins all segments with spaces — convenient for piping into
word counts, LLM prompts, or search tools:

```sh
ytt dQw4w9WgXcQ | wc -w
ytt dQw4w9WgXcQ | grep -i "never"
```

With `--timestamps` (`-t`), each segment is on its own line:

```
[00:00] Never gonna give you up
[00:03] Never gonna let you down
[00:07] Never gonna run around and desert you
...
```

## Flags

| Flag | Purpose |
|---|---|
| `-t`, `--timestamps` | Prefix each segment with `[mm:ss]` (or `[h:mm:ss]` for long videos), one per line |
| `--version` | Print version |
| `--help` | Print usage |
| `--help-agent` | Extended help oriented toward AI/agent consumers |

## Subcommands

| Command | Purpose |
|---|---|
| `ytt ingest [PLAYLIST_URL]` | Bulk-ingest a playlist + tracked channels — see [Playlist ingest](#playlist-ingest) below |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All transcripts fetched successfully |
| 1 | One or more videos failed (unavailable, transcripts disabled, etc.) |
| 2 | Usage error (no arguments, bad flag) |

Errors are written to stderr, one line per failure, in the form
`ytt: <video-id>: <reason>`.

## Playlist ingest

`ytt ingest` is a bulk workflow for building a local knowledge base of
video transcripts and synopses. It walks a YouTube playlist and any
tracked channels, fetches transcripts for new videos, and writes one
directory per video under `$YOUTUBE_INGEST_ROOT`.

```sh
export YOUTUBE_INGEST_PLAYLIST=https://www.youtube.com/playlist?list=PL...
export YOUTUBE_INGEST_ROOT=~/knowledge/youtube
ytt ingest
```

### What lands on disk

```
$YOUTUBE_INGEST_ROOT/
├── <video-id>/
│   ├── .transcript/transcript.md   # raw transcript (hidden from Obsidian graph)
│   ├── metadata.json               # title, channel, upload date, duration, …
│   └── <slug>.md                   # synopsis (generated via `claude`)
├── .processed                      # dedup state (one video ID per line)
├── .channels/<handle>              # per-channel cursor file
├── .ingest.log                     # append-only run log
└── youtube-knowledge-base.md       # index, regenerated from the per-video files
```

### Configuration

| Env var | Default | Purpose |
|---|---|---|
| `YOUTUBE_INGEST_PLAYLIST` | (required) | Playlist URL. Can be passed as the first arg instead. |
| `YOUTUBE_INGEST_ROOT` | `~/think/knowledge/youtube` | Where ingested videos land. |
| `YOUTUBE_CHANNELS_FILE` | bundled `channels.yaml` | YAML list of channels to track newest-first. |
| `YOUTUBE_INGEST_CONCURRENCY` | `4` | Parallel video workers. |

### Tracking channels (optional)

Copy the bundled example to enable channel ingest:

```sh
cp "$(dirname "$(realpath "$(command -v ytt)")")/scripts/playlist-ingest/channels.example.yaml" \
   ~/my-channels.yaml
$EDITOR ~/my-channels.yaml
export YOUTUBE_CHANNELS_FILE=~/my-channels.yaml
ytt ingest
```

On first sight of a channel, the latest video is ingested and recorded
as a cursor — no backfill of older uploads. Subsequent runs walk newer
videos until the cursor is hit. If `channels.yaml` is missing, ingest
falls back to playlist-only mode.

### Runtime dependencies

`ytt ingest` shells out to `yt-dlp`, `jq`, and `yq`; the synopsis step
also runs `claude` (Claude Code CLI). The Homebrew formula declares
`yt-dlp`, `jq`, and `yq` as `depends_on`; install `claude` separately
via `npm i -g @anthropic-ai/claude-code` if you want synopses.

## Requirements

- Internet access to YouTube (the underlying library scrapes YouTube's
  caption endpoints; YouTube occasionally changes these and breaks
  transcript fetching until the library catches up)
- Python 3.10+ only if installing from source; the Homebrew and
  GitHub-release downloads bundle their own interpreter
- For `ytt ingest`: `yt-dlp`, `jq`, `yq` on PATH (auto-installed via
  Homebrew), plus optionally `claude` (npm) for synopsis generation

## License

Apache 2.0 — see [LICENSE](LICENSE).
