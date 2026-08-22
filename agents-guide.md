ytt — YouTube transcript fetcher for CLI use.

For an agentic coding tool, include this file in the project context or run
`ytt --help-agent` (usage text, then this guide).

Usage:
  ytt <video>                      plain transcript (single line, space-joined)
  ytt -t <video>                   one segment per line, prefixed with [mm:ss]
  ytt --json <video>               transcript payload as JSON (one object per video)
  ytt <v1> <v2> ...                multiple videos, separated by a blank line
                                   (or one JSON object per line with --json)
  ytt ingest [PLAYLIST_URL]        download then analyze (two fan-outs)
  ytt ingest --download            paced YouTube fetch only
  ytt ingest --analyze             unthrottled synopsis of on-disk downloads
  ytt ingest --dry-run             report the queues without fetching or spending
  ytt build-index                  regenerate youtube-knowledge-base.md
  ytt synopsis --dir DIR --title T --url URL
                                   write one synopsis via Claudia
                                   (ladder: grok → claude → codex)

Accepted input forms:
  dQw4w9WgXcQ                      raw 11-character video ID
  https://www.youtube.com/watch?v=dQw4w9WgXcQ
  https://youtu.be/dQw4w9WgXcQ
  https://youtube.com/shorts/dQw4w9WgXcQ

Output:
  Transcript text goes to stdout. Errors go to stderr, one line per failure,
  in the form "ytt: <video-id>: <reason>".

  --json emits one compact JSON object per video on its own line (JSONL for
  multi-video inputs). Schema:
    {
      "video_id": "<id>",
      "language": "English",
      "language_code": "en",
      "is_generated": false,
      "snippets": [{"text": "...", "start": 0.0, "duration": 2.5}, ...]
    }
  Pipe through `jq .` for human-readable output.

Exit codes:
  0   all requested transcripts fetched successfully
  1   at least one video failed (unavailable, transcripts disabled, etc.)
  2   usage error (no arguments, bad flag)

Agent tips:
  - Use --json when you want per-segment timing, language metadata, and
    the auto-generated flag. The object shape is ytt's public JSON
    contract, not a raw yt-dlp dump.
  - Prefer -t/--timestamps when you want human-readable timestamps but
    don't need the structured payload.
  - Without -t/--json, the transcript is a single long line — good for
    passing directly into an LLM prompt or piping through `wc -w`.
  - Errors are plain text; no need to parse JSON.
  - `ytt ingest` is a thin wrapper around the bundled bash workflow under
    scripts/playlist-ingest/. Configure via env vars (see README §Playlist
    ingest); requires `yt-dlp`, `jq`, `yq`, and `timeout`/`gtimeout` on PATH.
    Synopses are `ytt synopsis` (Claudia), not `claude -p`.
  - Channel config lives in `$XDG_CONFIG_HOME/ytt/channels.yaml` (normally
    ~/.config/ytt/channels.yaml), NOT beside the installed scripts — the
    Homebrew prefix is replaced on every upgrade, so config stored there
    silently disappears and channel ingest turns into a no-op.
  - Unhealthy scheduled runs report events to blurter; ytt does not send
    Slack DMs or banners itself. A run that ingests nothing for
    $YOUTUBE_INGEST_STALE_DAYS while channels are tracked is itself
    treated as a failure. Use `--dry-run` to inspect the resolved config
    and pending queue without fetching or spending.
  - `$ROOT/.download-failed` records only genuine YouTube dead-ends (no
    captions, members-only, private/unavailable). Transient IO, empty
    stderr, 429, and timeouts retry and do not poison the ID. Members-only
    (`subscriber_only` and kin) is skipped at listing so it never takes a
    paced download slot.
  - Video IDs may start with `-`. `ytt ingest` accepts them as operands.
    Bare `ytt -XXXX` is still a flag to the Go CLI; pass a URL instead.
