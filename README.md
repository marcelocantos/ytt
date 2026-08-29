# ytt

Fetch YouTube video transcripts from the command line.

A thin wrapper around [`yt-dlp`](https://github.com/jdepoix/yt-dlp)
that extracts video IDs from URLs, handles multiple videos, and optionally
prefixes each segment with a timestamp.

## Install

### Homebrew (recommended)

```sh
brew install marcelocantos/tap/ytt
```

### From the GitHub release

Each release attaches a static Go binary plus the bundled `scripts/`
tree for macOS arm64, Linux x86_64, and Linux arm64. Download the
tarball matching your platform from the
[releases page](https://github.com/marcelocantos/ytt/releases/latest),
extract, put `ytt` on your PATH, and keep `scripts/` beside the binary
(or in `../libexec/scripts/` relative to it).

### From source

Requires Go 1.26+. Clone the repo and build so `scripts/` stays next to
the binary (`ytt ingest` and `ytt synopsis` resolve that tree at
runtime; `go install` puts only the binary in `GOBIN` and those
subcommands then fail):

```sh
git clone https://github.com/marcelocantos/ytt
cd ytt
go build -o ytt .
```

## Usage

```sh
ytt dQw4w9WgXcQ                                  # raw video ID
ytt https://www.youtube.com/watch?v=dQw4w9WgXcQ  # full URL
ytt https://youtu.be/dQw4w9WgXcQ                 # short URL
ytt --timestamps dQw4w9WgXcQ                     # one line per segment, [mm:ss] prefix
ytt --json dQw4w9WgXcQ                           # transcript payload as JSON
ytt <id1> <id2> <id3>                            # multiple videos, blank line between
```

If you use an agentic coding tool, include [`agents-guide.md`](agents-guide.md)
in the project context, or run `ytt --help-agent`.

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

With `--json`, the transcript payload is emitted — per-segment timing,
language metadata, and the auto-generated flag — one compact JSON object
per video (JSONL for multi-video):

```sh
ytt --json dQw4w9WgXcQ | jq .
```

```json
{
  "video_id": "dQw4w9WgXcQ",
  "language": "English",
  "language_code": "en",
  "is_generated": false,
  "snippets": [
    {"text": "Never gonna give you up", "start": 0.0, "duration": 2.5},
    ...
  ]
}
```

## Flags

| Flag | Purpose |
|---|---|
| `-t`, `--timestamps` | Prefix each segment with `[mm:ss]` (or `[h:mm:ss]` for long videos), one per line |
| `-j`, `--json` | Emit the transcript payload as JSON (one object per video, JSONL for multi). Mutually exclusive with `-t`. |
| `--version` | Print version |
| `--help` | Print usage |
| `--help-agent` | Extended help oriented toward AI/agent consumers (embeds [`agents-guide.md`](agents-guide.md)) |

## Subcommands

| Command | Purpose |
|---|---|
| `ytt ingest [PLAYLIST_URL]` | Download then analyze (two fan-outs) — see [Playlist ingest](#playlist-ingest) below |
| `ytt ingest --download` | Paced YouTube fetch only (transcript + meta). Bounded per tick. |
| `ytt ingest --analyze` | Unthrottled synopsis of on-disk downloads not yet in `.processed` |
| `ytt build-index` | Regenerate `youtube-knowledge-base.md` from recent ingested synopses (default: last 7 days of uploads) |
| `ytt synopsis --dir DIR --title TITLE --url URL` | Write one video's synopsis via Claudia (grok → claude → codex) |

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
│   ├── .transcript/transcript.json # full yt-dlp payload (hidden from Obsidian graph)
│   ├── meta.json                   # title, channel, upload date, duration, …
│   └── <slug>.md                   # synopsis (Claudia: grok → claude → codex)
├── .processed                      # dedup state (one video ID per line)
├── .download-failed                # genuine YouTube dead-ends only (skipped later)
├── .channels/<handle>              # per-channel cursor file
├── .ingest.log                     # append-only run log
└── youtube-knowledge-base.md       # index, regenerated from the per-video files
```

`.download-failed` is a skip ledger, not a dump of every fetch error. Only
genuine YouTube dead-ends are recorded: no captions (`TranscriptsDisabled` /
`NoTranscriptFound`), members-only / unplayable, private, or
`VideoUnavailable`. IO races (`No such file`), empty stderr, 429s, and
timeouts retry on the next download tick and do not poison the ID.

Members-only videos (`subscriber_only`, `unlisted_subscriber_only`,
`premium_only`, `needs_auth`, `private`) are skipped at listing time — they
never occupy a paced download slot. Hopper IDs that never appear in a listing
this tick are still tried once.

Video IDs may start with `-`. `ytt ingest` treats an 11-character
`[A-Za-z0-9_-]` token as an ID, not a flag. Bare `ytt -Gj0-EIyx6g` is still
parsed as flags by the Go CLI — pass a URL in that case.

### Configuration

| Env var | Default | Purpose |
|---|---|---|
| `YOUTUBE_INGEST_PLAYLIST` | (required) | Playlist URL. Can be passed as the first arg instead. |
| `YOUTUBE_INGEST_ROOT` | `~/think/knowledge/youtube` | Where ingested videos land. |
| `YOUTUBE_CHANNELS_FILE` | `~/.config/ytt/channels.yaml` | YAML list of channels to track newest-first. Resolved from `$XDG_CONFIG_HOME/ytt/` — **not** the install directory, which a `brew upgrade` replaces. |
| `YOUTUBE_INGEST_CONCURRENCY` | `4` | Parallel download workers. |
| `YOUTUBE_INGEST_ANALYZE_CONCURRENCY` | same as download | Parallel analyze workers (no YouTube pacing). |
| `YOUTUBE_INGEST_DOWNLOAD_BATCH` | `16` | Max videos fetched per download tick. Remainder waits for the next tick. `0` disables. |
| `YOUTUBE_INGEST_YTT_BIN` | `ytt` (PATH) | Absolute path to the `ytt` used for transcript fetches and `ytt synopsis`. Pin it in scheduled runs so launchd and your shell can't resolve two different builds. |
| `YOUTUBE_INGEST_SYNOPSIS_PROVIDERS` | `grok,claude,codex` | Claudia Task ladder for synopses. Capacity/spend/rate-limit on one provider falls through to the next. |
| `YOUTUBE_INGEST_LOG` | `$YOUTUBE_INGEST_ROOT/.ingest.log` | Ingest log path. Point it outside the content tree for scheduled runs. |
| `YOUTUBE_INGEST_NETWORK_WAIT` | `14400` | Seconds to wait (awake-time) for connectivity before giving up — covers launchd ticks that fire in a no-network DarkWake window. |
| `YOUTUBE_INGEST_STALE_DAYS` | `7` | Days of zero ingests (with channels tracked) before the run is judged unhealthy. `0` disables the check. |
| `YOUTUBE_INDEX_RECENT_DAYS` | `7` | `ytt build-index` includes only videos whose YouTube upload date is on or after today minus this many days. `0` lists the full catalog. Older synopses stay on disk. |
| `YOUTUBE_INGEST_STATE_DIR` | `~/.local/state/ytt` | Where the liveness stamp lives. Kept out of the content tree. |
| `YOUTUBE_INGEST_QUEUE` | `$YOUTUBE_INGEST_STATE_DIR/backfill.ids` | Optional extra video-ID hopper (one ID per line). Deduped against `.processed` each run and drained by the same paced workers as the playlist. |
| `YOUTUBE_INGEST_BLURTER_BIN` | `blurter` (PATH) | The blurter binary used to report events. Pin it in scheduled runs. |

### Scheduling

Two launchd jobs: a paced **download** tick every 20 minutes and an
unthrottled **analyze** tick every 10 minutes. They run whenever the
laptop is awake.

```sh
cp scripts/playlist-ingest/launchd/com.marcelocantos.youtube-*.plist \
   ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.marcelocantos.youtube-ingest.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.marcelocantos.youtube-analyze.plist
```

Both pin the `ytt` binary and write logs to
`~/.local/var/log/youtube-ingest/` (not into the content tree). Edit the
playlist URL and paths in the download plist first; they are
machine-specific. A tick that fires while the machine is asleep or
between networks waits for connectivity rather than recording a false
"nothing new".

### Tracking channels (optional)

Channel config lives in `~/.config/ytt/channels.yaml`:

```sh
mkdir -p ~/.config/ytt
cp "$(brew --prefix ytt)/libexec/scripts/playlist-ingest/channels.example.yaml" \
   ~/.config/ytt/channels.yaml
$EDITOR ~/.config/ytt/channels.yaml
ytt ingest --dry-run     # confirm the channels are seen before ingesting
```

Resolution order is `$YOUTUBE_CHANNELS_FILE`, then
`$XDG_CONFIG_HOME/ytt/channels.yaml` (default `~/.config/ytt/`), then a
copy beside the scripts (dev checkouts only). Keep your config out of the
install directory: Homebrew replaces `.../Cellar/ytt/<version>/libexec/`
wholesale on every upgrade, so config stored there disappears silently.

On first sight of a channel, the latest video is ingested and recorded
as a cursor — no backfill of older uploads. Subsequent runs walk newer
videos until the cursor is hit. With no channels file at all, ingest
runs in playlist-only mode.

If a channels file goes missing while `.channels/<handle>` cursors still
exist, that is treated as an **orphaned config** — a real failure, not a
preference — and the run fails loudly instead of reporting "nothing to
do". This case cost 15 days of silent no-ops before v0.10.0.

### Alerting

ytt does not deliver notifications. It **reports events** to
[blurter](https://github.com/marcelocantos/blurter), which owns the Slack
credential, the delivery policy (dedup, re-notify windows, recovery notices) and
the sinks. blurter is a hard dependency, declared by the Homebrew formula.

```sh
brew services start blurter    # if it isn't already running
```

Configure Slack once, in blurter, not per app — see its README. ytt holds no
credential and needs no notification configuration of its own.

A run is unhealthy when any of these hold, and each is reported as a `problem`
event:

- a preflight abort (missing `ytt`/`curl`, or network never returned)
- a discovery source failed (playlist or channel feed)
- a channels config was orphaned (see above)
- downloading itself is failing this tick (pending misses outnumber successful fetches, or nothing succeeded), or the run watchdog fired. A single ID that stays pending while neighbours download is video trouble, logged and retried, not an unhealthy run
- every available synopsis provider hit a capacity/spend/rate limit (`ytt synopsis` exit 255), so the analyze tick cut short; a mixed ladder failure (unusable or empty reply plus a last-rung capacity miss) fails that video only (exit 1) and does not abort the queue
- the knowledge-base index failed to refresh
- **nothing has been ingested for `YOUTUBE_INGEST_STALE_DAYS` days** while
  channels are tracked — the liveness backstop for "every step succeeded and yet
  no knowledge arrived"

A healthy run reports an `ok` event, which blurter keeps silent unless it closes
out a problem it previously reported.

`blurter send` spools and exits, so reporting never blocks the ingest and never
fails it, and an alert raised while the machine is offline is still delivered
later. Repeat suppression, `RECOVERED` notices and sink fallback all live in
blurter — ytt deliberately implements none of it.

Use `ytt ingest --dry-run` to run discovery and the health checks and print the
queue without fetching transcripts, running `ytt synopsis`, or reporting events.

### Runtime dependencies

`ytt` fetches captions with `yt-dlp`. `ytt ingest` also needs `jq`,
`yq`, and GNU `timeout`/`gtimeout` (Homebrew `coreutils` on macOS).
Synopses go through `ytt synopsis`, which runs a Claudia Task ladder
(default `grok,claude,codex`) and writes the file itself — ingest does
not shell out to `claude -p`. The Homebrew formula declares `yt-dlp`,
`jq`, `yq`, `coreutils`, and `blurter` as `depends_on`. Provider CLIs
(`grok`, `claude`, `codex`) are resolved by Claudia; pin `GROK_BIN` /
`CLAUDE_BIN` / `CODEX_BIN` in scheduled runs.

The bundled launchd plists pin `ytt` and those provider binaries to
absolute paths. A scheduled run that does not land discovered videos is
a failed run, not a successful empty tick.

## Requirements

- Internet access to YouTube (`yt-dlp` pulls caption tracks; YouTube
  occasionally changes these and breaks fetching until yt-dlp catches up)
- Go 1.26+ only if building from source; Homebrew and GitHub-release
  downloads are a static binary plus the bundled `scripts/` tree
- For `ytt ingest`: `yt-dlp`, `jq`, `yq`, and `timeout`/`gtimeout` on
  PATH (auto-installed via Homebrew), plus at least one Claudia
  provider CLI for synopsis generation

## License

Apache 2.0 — see [LICENSE](LICENSE).
