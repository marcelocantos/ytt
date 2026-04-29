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

Snapshot as of v0.5.0.

### CLI — `ytt` (transcript)

| Form | Stability |
|---|---|
| `ytt <video>...` (positional video IDs/URLs) | Stable |
| `ytt -t <video>` / `ytt --timestamps <video>` | Stable |
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
- Errors on stderr, one line per failure, `ytt: <video-id>: <reason>`.
- Exit codes `0` (all ok), `1` (≥1 video failed), `2` (usage error).

### CLI — `ytt ingest` (subcommand, new in v0.5.0)

| Form | Stability |
|---|---|
| `ytt ingest [PLAYLIST_URL]` | Needs review |

Behaviour: passes through to the bundled
`scripts/playlist-ingest/ingest.sh`, with all remaining args forwarded
verbatim. Subcommand surface is fluid until the underlying scripts
settle (see **Playlist-ingest workflow** below).

### Playlist-ingest workflow — env vars

| Variable | Default | Stability |
|---|---|---|
| `YOUTUBE_INGEST_PLAYLIST` | (required if not passed positionally) | Needs review |
| `YOUTUBE_INGEST_ROOT` | `~/think/knowledge/youtube` | Needs review |
| `YOUTUBE_CHANNELS_FILE` | `<scripts-dir>/channels.yaml` | Fluid |
| `YOUTUBE_INGEST_CONCURRENCY` | `4` | Stable |

The default `YOUTUBE_INGEST_ROOT` of `~/think/knowledge/youtube` is
personal-vault-shaped and likely to move to something neutral
(e.g. `~/ytt-knowledge`) before 1.0.

### Playlist-ingest workflow — on-disk layout

| Path | Stability |
|---|---|
| `$ROOT/<video-id>/.transcript/transcript.md` | Needs review |
| `$ROOT/<video-id>/metadata.json` (yt-dlp JSON shape) | Needs review |
| `$ROOT/<video-id>/<slug>.md` (synopsis) | Fluid |
| `$ROOT/.processed` (one ID per line) | Stable |
| `$ROOT/.channels/<handle>` (cursor file) | Stable |
| `$ROOT/.ingest.log` | Stable |
| `$ROOT/youtube-knowledge-base.md` (index) | Fluid |

The synopsis file's filename convention (topic slug) and TL;DR-line
contract emerged from real use; both are still settling. The index
table format has changed once (v0.5.0: two-column layout) and may
change again.

### Channel config schema (`channels.yaml`)

```yaml
channels:
  - handle: <youtube-handle>          # required, with or without leading "@"
    name: <display-name>              # optional, cosmetic
```

Stability: Needs review. The handle/name pair is the minimum viable
schema; per-channel options (filters, ingest cadence, alternative
URLs) are likely to land before 1.0.

### Distribution

| Channel | Stability |
|---|---|
| Homebrew formula `marcelocantos/tap/ytt` | Stable |
| GitHub release tarballs (`darwin-arm64`, `linux-amd64`, `linux-arm64`) | Stable |
| `pipx install git+https://github.com/marcelocantos/ytt` | Stable |
| PyPI publishing | Out of scope (deferred) |

## Gaps and prerequisites for 1.0

- **Synopsis convention**: the `<slug>.md` filename and TL;DR-line
  contract need a written spec. Currently emergent from `ingest-one.sh`
  prompts; should be documented and tested.
- **Knowledge-base index format**: the two-column layout shipped in
  v0.5.0 is the second iteration. Settle on a final schema (and ideally
  a test) before locking in.
- **`YOUTUBE_INGEST_ROOT` default**: change from `~/think/knowledge/youtube`
  to a neutral default before 1.0.
- **Test coverage**: only CLI flag smoke checks and two helper unit
  asserts exist. No tests for the ingest path, the channel walker, or
  the index regeneration. At minimum, the channel cursor protocol
  needs a test before 1.0.
- **`claude` (npm) dependency**: `ingest-one.sh` shells out to `claude`
  for synopsis generation. Document the expected version range, or
  parameterise so users can swap the LLM.
- **Network-independent transcript test**: the helper unit checks
  don't exercise transcript parsing. A canned-response fixture
  would help catch upstream breakage early.
- **PyPI publishing**: trusted-publisher setup deferred from v0.1.0
  due to hCaptcha outage. Re-enable before 1.0 so non-Homebrew users
  have a maintained install path.

## Out of scope for 1.0

- A `ytt ingest <video-id>` single-video subcommand (the
  `ingest-one.sh` script covers this for now and isn't worth surfacing
  as a first-class subcommand).
- Live, watched-folder ingest (current model is one-shot per
  invocation).
- Synopsis generation without `claude` — the ingest workflow leaves
  the LLM choice as a deliberate dependency, not a built-in feature.
- Obsidian-specific schema additions (frontmatter tags, dataview
  hints). The on-disk layout stays markdown-with-conventions.
