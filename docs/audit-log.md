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
