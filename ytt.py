# Copyright 2026 Marcelo Cantos
# SPDX-License-Identifier: Apache-2.0

"""Fetch YouTube video transcripts from the command line."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from youtube_transcript_api import YouTubeTranscriptApi
from youtube_transcript_api._errors import CouldNotRetrieveTranscript

__version__ = "0.9.0"


AGENT_HELP = """\
ytt — YouTube transcript fetcher for CLI use.

Usage:
  ytt <video>                      plain transcript (single line, space-joined)
  ytt -t <video>                   one segment per line, prefixed with [mm:ss]
  ytt --json <video>               full API payload as JSON (one object per video)
  ytt <v1> <v2> ...                multiple videos, separated by a blank line
                                   (or one JSON object per line with --json)
  ytt ingest [PLAYLIST_URL]        bulk-ingest a playlist + tracked channels

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
  - Use --json when you want to preserve everything the upstream API
    returns (per-segment timing, language metadata, auto-generated flag).
  - Prefer -t/--timestamps when you want human-readable timestamps but
    don't need the structured payload.
  - Without -t/--json, the transcript is a single long line — good for
    passing directly into an LLM prompt or piping through `wc -w`.
  - Errors are plain text; no need to parse JSON.
  - `ytt ingest` is a thin wrapper around the bundled bash workflow under
    scripts/playlist-ingest/. Configure via env vars (see README §Playlist
    ingest); requires `yt-dlp`, `jq`, and `yq` on PATH.
"""


def _scripts_dir() -> Path:
    """Locate the bundled scripts/ directory for both frozen and source runs."""
    if getattr(sys, "frozen", False):
        # PyInstaller --onedir: scripts/ sits next to the binary in dist/ytt/.
        # The brew formula's `libexec.install Dir["*"]` carries that layout
        # into libexec/, so resolving via sys.executable works in both.
        return Path(sys.executable).resolve().parent / "scripts"
    return Path(__file__).resolve().parent / "scripts"


def _run_ingest(args: list[str]) -> int:
    """Exec the bundled playlist-ingest entry script with the remaining args."""
    script = _scripts_dir() / "playlist-ingest" / "ingest.sh"
    if not script.is_file():
        print(
            f"ytt: ingest script not found at {script}\n"
            "(this build was not packaged with the playlist-ingest scripts)",
            file=sys.stderr,
        )
        return 2
    os.execvp("bash", ["bash", str(script), *args])  # noqa: returns via exec


def extract_video_id(arg: str) -> str:
    """Pull a video ID out of a raw ID or a YouTube URL."""
    if "v=" in arg:
        return arg.split("v=", 1)[1].split("&", 1)[0]
    if "youtu.be/" in arg or "/shorts/" in arg or "/embed/" in arg:
        tail = arg.rstrip("/").split("/")[-1]
        return tail.split("?", 1)[0]
    return arg


def format_timestamp(seconds: float) -> str:
    total = int(seconds)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"[{h:d}:{m:02d}:{s:02d}]"
    return f"[{m:02d}:{s:02d}]"


def fetch_transcript(video_id: str, mode: str) -> str:
    transcript = YouTubeTranscriptApi().fetch(video_id)
    if mode == "json":
        # Mirror the FetchedTranscript public surface verbatim — anything
        # the upstream library exposes about the fetch should land here so
        # downstream consumers don't lose fidelity. `to_raw_data()` already
        # serialises snippets as {text, start, duration}.
        payload = {
            "video_id": transcript.video_id,
            "language": transcript.language,
            "language_code": transcript.language_code,
            "is_generated": transcript.is_generated,
            "snippets": transcript.to_raw_data(),
        }
        return json.dumps(payload, ensure_ascii=False)
    if mode == "timestamps":
        return "\n".join(
            f"{format_timestamp(item.start)} {item.text}" for item in transcript
        )
    return " ".join(item.text for item in transcript)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ytt",
        description=(
            "Fetch YouTube video transcripts. "
            "Run `ytt ingest [PLAYLIST_URL]` for the bulk playlist + channel "
            "ingest workflow (see README)."
        ),
    )
    parser.add_argument(
        "videos",
        nargs="*",
        metavar="VIDEO",
        help="YouTube video ID or URL (one or more)",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "-t", "--timestamps",
        action="store_true",
        help="prefix each segment with its [mm:ss] timestamp",
    )
    mode.add_argument(
        "--json",
        action="store_true",
        help="emit the full API payload as JSON (one object per video, JSONL for multi)",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"ytt {__version__}",
    )
    parser.add_argument(
        "--help-agent",
        action="store_true",
        help="print extended help tailored for AI agents",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    raw = sys.argv[1:] if argv is None else argv
    # The `ingest` subcommand is a passthrough to the bundled bash workflow;
    # short-circuit before argparse so flags like `--playlist-end` reach it
    # untouched.
    if raw and raw[0] == "ingest":
        return _run_ingest(raw[1:])

    parser = build_parser()
    args = parser.parse_args(raw)

    if args.help_agent:
        sys.stdout.write(AGENT_HELP)
        return 0

    if not args.videos:
        parser.error("at least one VIDEO argument is required")

    mode = "json" if args.json else "timestamps" if args.timestamps else "plain"

    exit_code = 0
    for i, raw in enumerate(args.videos):
        # Text modes use a blank line between videos; JSON mode is JSONL,
        # so each object's trailing newline is the only separator.
        if i and mode != "json":
            print()
        video_id = extract_video_id(raw)
        try:
            print(fetch_transcript(video_id, mode))
        except CouldNotRetrieveTranscript as e:
            reason = type(e).__name__
            print(f"ytt: {video_id}: {reason}", file=sys.stderr)
            exit_code = 1
        except Exception as e:
            print(f"ytt: {video_id}: {type(e).__name__}: {e}", file=sys.stderr)
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
