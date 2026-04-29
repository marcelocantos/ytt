# Copyright 2026 Marcelo Cantos
# SPDX-License-Identifier: Apache-2.0

"""Fetch YouTube video transcripts from the command line."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from youtube_transcript_api import YouTubeTranscriptApi
from youtube_transcript_api._errors import CouldNotRetrieveTranscript

__version__ = "0.5.0"


AGENT_HELP = """\
ytt — YouTube transcript fetcher for CLI use.

Usage:
  ytt <video>                      plain transcript (single line, space-joined)
  ytt -t <video>                   one segment per line, prefixed with [mm:ss]
  ytt <v1> <v2> ...                multiple videos, separated by a blank line
  ytt ingest [PLAYLIST_URL]        bulk-ingest a playlist + tracked channels

Accepted input forms:
  dQw4w9WgXcQ                      raw 11-character video ID
  https://www.youtube.com/watch?v=dQw4w9WgXcQ
  https://youtu.be/dQw4w9WgXcQ
  https://youtube.com/shorts/dQw4w9WgXcQ

Output:
  Transcript text goes to stdout. Errors go to stderr, one line per failure,
  in the form "ytt: <video-id>: <reason>".

Exit codes:
  0   all requested transcripts fetched successfully
  1   at least one video failed (unavailable, transcripts disabled, etc.)
  2   usage error (no arguments, bad flag)

Agent tips:
  - Prefer -t/--timestamps when the downstream task cares about *when*
    something was said (summarisation with citations, jumping to timestamps).
  - Without -t, the transcript is a single long line — good for passing
    directly into an LLM prompt or piping through `wc -w`.
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


def fetch_transcript(video_id: str, timestamps: bool) -> str:
    api = YouTubeTranscriptApi()
    transcript = api.fetch(video_id)
    if timestamps:
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
    parser.add_argument(
        "-t", "--timestamps",
        action="store_true",
        help="prefix each segment with its [mm:ss] timestamp",
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

    exit_code = 0
    for i, raw in enumerate(args.videos):
        if i:
            print()
        video_id = extract_video_id(raw)
        try:
            print(fetch_transcript(video_id, args.timestamps))
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
