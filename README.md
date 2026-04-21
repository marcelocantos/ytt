# ytt

Fetch YouTube video transcripts from the command line.

A thin wrapper around [`youtube-transcript-api`](https://github.com/jdepoix/youtube-transcript-api)
that extracts video IDs from URLs, handles multiple videos, and optionally
prefixes each segment with a timestamp.

## Install

```sh
uv tool install ytt        # recommended
pipx install ytt           # alternative
```

Either puts a `ytt` command on your PATH in an isolated environment.

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

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All transcripts fetched successfully |
| 1 | One or more videos failed (unavailable, transcripts disabled, etc.) |
| 2 | Usage error (no arguments, bad flag) |

Errors are written to stderr, one line per failure, in the form
`ytt: <video-id>: <reason>`.

## Requirements

- Python 3.10+
- Internet access to YouTube (the underlying library scrapes YouTube's
  caption endpoints; YouTube occasionally changes these and breaks
  transcript fetching until the library catches up)

## License

Apache 2.0 — see [LICENSE](LICENSE).
