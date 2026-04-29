# Audit Log

Chronological record of audits, releases, documentation passes, and other
maintenance activities. Append-only — newest entries at the bottom.

## 2026-04-22 — /open-source ytt v0.1.0

- **Commit**: `efd9eca`
- **Outcome**: Initial open-sourcing of the ytt script. Inline audit (30-line
  project — full /audit delegation would have been disproportionate) found 8
  issues (0 critical, 1 high: `--help`/`--version` crashed with a traceback
  because there was no argparse; everything else medium/low). All issues fixed:
  argparse-driven CLI with `--help`, `--version`, `--help-agent`,
  `--timestamps`; clean one-line error messages (no tracebacks); proper exit
  codes (0/1/2). Packaged for PyPI (setuptools flat py-modules layout) but
  distribution path is currently Homebrew tap only — PyPI trusted-publisher
  setup was blocked by an hCaptcha outage. Released v0.1.0 with sdist + wheel
  attached to the GitHub release and a working Homebrew formula
  (`marcelocantos/tap/ytt`) using `virtualenv_install_with_resources` with
  pinned resources for youtube-transcript-api, requests, urllib3, certifi,
  idna, charset-normalizer, defusedxml. CI runs smoke checks + helper unit
  checks across Python 3.10–3.13.
- **Deferred**:
  - PyPI publishing (release.yml PyPI job removed; re-add once the trusted
    publisher is registered at https://pypi.org/manage/account/publishing/)
  - No tests beyond CLI flag smoke checks and two helper unit asserts; no
    network-independent test of transcript parsing
  - Formula deps will drift over time — there's no automation to refresh
    `resource` blocks on youtube-transcript-api updates

## 2026-04-22 — /release v0.2.0 (via session follow-up)

- **Commit**: `714b46c`
- **Outcome**: Switched distribution from a Python-venv formula
  (`virtualenv_install_with_resources`) to a PyInstaller single-binary per
  platform. `brew install` time dropped from ~60s to ~5s. release.yml now
  matches the mainstream `/release` skill pattern (matrix build →
  `<project>-<version>-<os>-<arch>.tar.gz` → homebrew-releaser). The
  custom `scripts/brew-formula-gen.py` and custom tap-push job are gone.
  The "Python is different" framing from the /open-source run turned out
  to be wrong: once the artefact is a binary, /release's binary path
  applies verbatim. `HOMEBREW_TAP_TOKEN` was already set from the
  previous run.
- **Deferred**:
  - PyInstaller `--onefile` startup cost (~4s per invocation) — addressed
    in v0.3.0 below

## 2026-04-22 — /release v0.3.0 (via session follow-up)

- **Commit**: `a55de4a`
- **Outcome**: Switched PyInstaller from `--onefile` to `--onedir` to fix
  v0.2.0's 4-second cold-start cost. Startup is now ~100ms hot, ~900ms
  cold — comparable to a native Go/Rust binary. Tarball now contains the
  binary plus `_internal/` at the root; the Homebrew formula moves both
  into libexec and symlinks the binary into bin. Total install time from
  `brew upgrade` is ~5s.

## 2026-04-27 — /release v0.4.0

- **Commit**: `4a512a0`
- **Outcome**: Released v0.4.0 (darwin-arm64, linux-amd64, linux-arm64).
  No change to the `ytt` CLI itself — the release ships
  `scripts/playlist-ingest/`, a set of companion bash scripts for
  batch-ingesting a YouTube playlist into a local Obsidian-vault
  knowledge base. Each ingested video produces a topic-slug-named
  synopsis (with a one-line TL;DR consumed by an auto-generated
  `youtube-knowledge-base.md` index) and parks the bulky raw transcript
  in a `.transcript/` dotfolder so Obsidian's graph view stays clean.
  The synopsis filename and TL;DR conventions emerged from real use
  against a 16-video playlist on 2026-04-26 — the original "everything
  is named synopsis.md" layout collapsed every graph node to the same
  label.
- **Deferred**:
  - `STABILITY.md` for the `ytt` CLI surface (pre-1.0 prerequisite).
    This release doesn't change the CLI, but the document is owed
    independently and the next CLI-touching release is the natural
    forcing function.

## 2026-04-28 — /release v0.5.0

- **Commit**: `82cbddb`
- **Outcome**: Made playlist ingest a first-class, brew-installable
  workflow. Three architectural fixes ride together:
  1. `ytt ingest [PLAYLIST_URL]` subcommand — passes through to the
     bundled `scripts/playlist-ingest/ingest.sh`; arg-parsed before
     argparse so all flags reach the bash workflow untouched. Resolves
     the scripts dir via `Path(sys.executable).resolve().parent` when
     frozen and `__file__` otherwise, so source and brew-installed runs
     share one code path.
  2. Release pipeline now copies `scripts/` into `dist/ytt/` before
     tarring. v0.4.0 had shipped the scripts in the source tree but
     PyInstaller's `--onedir` output dropped them, so the binary
     tarball brew downloads contained no scripts at all. (The audit-log
     for 🎯T1.1 records the discovery.)
  3. homebrew-releaser config grows a `depends_on:` block for `yt-dlp`,
     `jq`, and `yq`. Future releases regenerate the formula with these
     deps so `brew install ytt` is self-sufficient for the ingest path.
  Also: README gains a `## Playlist ingest` section with env-var
  reference, on-disk layout, and a copy-pasteable example.
  `channels.example.yaml` ships as a template; the active
  `channels.yaml` is gitignored so personal channel lists stay local.
- **Showcase**: 🎯T1 retired on demonstration of `ytt ingest` against
  a small playlist from a clean install — see release notes.
- **Deferred**:
  - `claude` (npm) is still required for synopsis generation in
    `ingest-one.sh` and is not in Homebrew. Documented in README,
    not blocked.
  - PyPI publishing (still deferred from v0.1.0; tracked in STABILITY.md
    gaps). Re-enable before 1.0.
- **STABILITY.md**: created in this release. Catalogues the CLI surface,
  the playlist-ingest env-var contract, and the on-disk knowledge-base
  layout, with stability annotations (Stable / Needs review / Fluid).
  Pre-1.0 — settling threshold not yet met.
