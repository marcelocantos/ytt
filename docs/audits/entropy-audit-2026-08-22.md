# Entropy audit — ytt — 2026-08-22

Full audit (architecture, redundancy, SDLC) plus explicit hygiene validation.
Mode: **full**. Hygiene skill invoked; `hygiene.yaml` is absent.

## Executive summary

- **Snapshot:** `/Users/marcelo/work/github.com/marcelocantos/ytt`
  - Branch: `go-build-index` (tracking `origin/go-build-index`, **ahead 10**)
  - HEAD: `fabf7ad25e513fbe5d79e2d81863594d7671020a` (`Decouple paced YouTube download from unthrottled analysis`)
  - Default branch `master` is at `a2e15a6` (`Port the ytt CLI to Go; drop Python and youtube-transcript-api (#26)`)
  - Initial dirty state: **clean** (`git status --porcelain=v1 -b` showed only the ahead-10 tracking line)
  - Date: 2026-08-22
- **Scope:** all tracked source, tests, CI, release, docs, launchd, and ingest scripts. No generated/vendored trees.
- **Exclusions:** gitignored `/ytt` binary and `/dist/`; live YouTube / live Claudia provider calls; Homebrew tap formula (sibling repo); parent `~/work/github.com/marcelocantos/go.work` (not this module).
- **Headline mechanism:** the shipped CLI is a Go binary, but the load-bearing ingest workflow is still an 851-line bash state machine exec'd by `ytt ingest`, while the public README / `STABILITY.md` still describe the retired Python/pipx/`claude -p` install and synopsis path.
- **Highest-consequence findings:** ENT-001 (dual-runtime ingest hub), ENT-002 (install/docs competing truth that would fail a from-source user).
- **Unverified residue:** live yt-dlp caption fetch; live Claudia grok/claude/codex synopsis; whether the next Homebrew formula from this branch matches the Go+scripts tarball; owner intent on personal launchd paths remaining in-tree.

No P0 current failure on the hermetic shipped path (Go tests + 62/62 bats green under `GOWORK=off`).

## Scope and exclusions

In scope:

- Go package `github.com/marcelocantos/ytt` (`main.go`, `transcript.go`, `index.go`, `synopsis.go` and tests)
- `scripts/playlist-ingest/` (ingest orchestration, bats, mocks, launchd, synopsis contract)
- `.github/workflows/{ci,release}.yml`, `Makefile`, `go.mod`/`go.sum`
- `README.md`, `STABILITY.md`, `agents-guide.md`, `docs/audit-log.md`, `bullseye.yaml`

Named exclusions (not silent omissions):

- Built artefact `/ytt` (gitignored)
- No `vendor/`, no generated protobuf/codegen trees
- `scripts/playlist-ingest/tests/mocks/` treated as test doubles, not production
- Live YouTube and live LLM backends (see Oracle coverage)

Languages analyzed: **Go** (`go.md` read) and **Bash** (`bash.md` read). No remaining `*.py`. `web-development.md` / `journeys.md` not applicable (CLI + scheduled ingest; no UI). No repo `AGENTS.md` / `CLAUDE.md`.

## Commands run

| Command | Version / notes | Exit | Shipped path? | Limitation |
|---|---|---|---|---|
| `git rev-parse HEAD`; `git status --porcelain=v1 -b` | git 2.55.0 | 0 | provenance | Working tree was clean |
| `go version` | go1.26.4 darwin/arm64 | 0 | toolchain | Local; CI pins `1.26` |
| `GOWORK=off go vet ./...` | go1.26.4 | 0 | auxiliary (same as Makefile `vet` *if* GOWORK off) | Makefile does not set `GOWORK=off` |
| `GOWORK=off go test ./... -count=1 -race` | go1.26.4 | 0 | local suite (Makefile `test-go` intent) | Fetch stubbed; Claudia provider stubbed |
| `make test-go` | GNU Make 3.81 | **2** | declared local suite | Fails: parent `go.work` does not list this module |
| `gofmt -l .` | gofmt from go1.26.4 | 0 (clean) | CI `gofmt` job | — |
| `GOWORK=off go build -o ytt .` | — | 0 | Makefile `build` / CI `build` | — |
| `/bin/bash -n scripts/playlist-ingest/*.sh` | bash 3.2.57 | 0 | CI `scripts-bash32` syntax step | `bash -n` does not catch bash-4 runtime constructs |
| `bats --tap scripts/playlist-ingest/tests/*.bats` | Bats 1.13.0 | 0 (62/62) | Makefile `test-scripts` / CI `scripts` + `scripts-bash32` | This run used Homebrew bash 5.3 on PATH, not the CI bash-3.2 shim |
| `go list -m all` | — | 0 | auxiliary | Workspace-visible module graph; claudia pulls a large indirect set |
| `hygiene.yaml` lookup | — | absent | — | Did not run `hygiene_check.py`; posture undeclared |

`make test-go` relevant output:

```
pattern ./...: directory prefix . does not contain modules listed in go.work or their selected dependencies
FAIL
make: *** [test-go] Error 1
```

Parent workspace file `/Users/marcelo/work/github.com/marcelocantos/go.work` contains only `./claudia` and `./jevons`. GitHub Actions checkouts have no parent workspace, so CI `go test ./...` is not this failure.

## Observed architecture

```
ytt (Go, package main)
├── transcript fetch  ──exec──► yt-dlp (json3 subs + --print-json)
├── build-index       ──rw──►   $YOUTUBE_INGEST_ROOT/youtube-knowledge-base.md
├── synopsis          ──lib──►  claudia.Task (grok → claude → codex)
│                               reads bundled synopsis-contract.md
└── ingest            ──exec──► scripts/playlist-ingest/ingest.sh
                                ├── discovery: yt-dlp playlist/channel + backfill queue
                                ├── download fan-out ──► ingest-one.sh --download
                                │                         ytt --json + yt-dlp meta
                                ├── analyze fan-out  ──► ingest-one.sh --analyze
                                │                         ytt synopsis
                                ├── health: ISSUES → blurter send
                                └── ytt build-index
```

**Declared and observed that agree**

- Transcript CLI is a thin yt-dlp wrapper; `--json` payload preserves the old Python shape (`transcript.go`, `STABILITY.md` CLI table).
- `ytt ingest` is a passthrough that locates bundled scripts next to the binary (`main.go:56-61`, `main.go:161-212`).
- Synopsis format has a written single source of truth (`scripts/playlist-ingest/synopsis-contract.md`), consumed at runtime by `ytt synopsis` and parsed by `ytt build-index`.
- Channel config resolves user-config-first, not from the install prefix (`ingest.sh:144-155`); orphaned config is a hard failure (bats cover it).
- Alerting is blurter's job; ytt only reports events (`ingest.sh:210-243`).
- Download and analyze are independent stages (`ingest.sh` `--download`/`--analyze`; two launchd plists).
- Release tarball bundles `scripts/` beside the binary (`.github/workflows/release.yml:62-67`); Homebrew formula moves that tree into `libexec`.

**Observed, inferred from code**

- Default ingest root is the owner's vault path `~/think/knowledge/youtube`, duplicated in shell and Go (`ingest.sh:119`, `ingest-one.sh:48`, `index.go:67-74`).
- Provider ladder default is `grok,claude,codex` (`synopsis.go:25`); Grok is first so Claude spend cannot red the run (🎯T17).
- Install-layout search is implemented twice (`ingestScript` vs `bundledPath`).

**Contradictions**

- README / `STABILITY.md` still document Python 3.10+, `pipx install`, and `claude` (npm) as the synopsis runtime. The tree has no `*.py`, `go.mod` requires Go 1.26.1, and `ingest-one.sh:187` calls `ytt synopsis`.
- `STABILITY.md` “Snapshot as of v0.5.0” and its 1.0 test-coverage gap list a suite that no longer exists (pytest / no ingest tests). 62 bats + Go tests exist.
- `docs/audit-log.md` stops at v0.5.0; the Go port is v0.11.0 (`main.go:22`).

**Unknown intent (owner)**

- Whether `~/think/knowledge/youtube` should remain the default until 1.0 (`STABILITY.md` already flags a move).
- Whether committed launchd plists should stay machine-specific (`/Users/marcelo/...`) or become placeholders.
- 🎯T7 (crosshair scheduler) remains `identified` and blocked on crosshair triggers.

### Dependency topology

- **Direct Go require:** `github.com/marcelocantos/claudia v0.25.0` only (`go.mod:5`).
- **Indirect:** AWS SDK / Bedrock, plus claudia's further graph (`go list -m all` also surfaces jevons, sqlite, quic-go, certmagic, …). Transcript fetch does not import those; synopsis does via claudia.
- **Runtime binaries (ingest):** `yt-dlp`, `jq`, `yq`, `timeout`/`gtimeout` (coreutils), `blurter`, plus Claudia-resolved `grok`/`claude`/`codex`.
- **No import cycles** in this repo: one `package main`.
- **High fan-in hub:** `scripts/playlist-ingest/ingest.sh` (19 commits in `git log --name-only` churn, highest of any file). `bullseye.yaml` (16) and `README.md` (13) co-change with it.

## Dimension vector

| Dimension | State | Evidence summary | Change from baseline |
|---|---|---|---|
| Architecture topology | concern | Clear Go CLI vs bash ingest split; ingest still owns cursors, fan-out, health | n/a (first full audit) |
| Redundancy / sources of truth | concern | Synopsis contract is one SoT; README/STABILITY/audit-log compete with code; duplicated path/root/timeout helpers | n/a |
| Change amplification | concern | ingest.sh + ingest-one.sh + plist + README + bats still move together; Go extracted index/synopsis but not orchestration | n/a |
| Local code quality | healthy | Go is linear and documented; bash is long but invariant-commented and 3.2-aware | n/a |
| Correctness / verification | concern | Strong hermetic oracles (Go + 62 bats + bash32 CI); Makefile `test-go` fails under parent go.work; no json3 fixture; no live Fetch/Claudia in CI | n/a |
| Security / dependencies | concern | Claude tool-strip present; Grok default path is not; claudia pulls a large graph; no scanner/dependabot | n/a |
| Build / release / operations | healthy | CI on ubuntu+macos, dedicated bash 3.2 job with version assert, release tag↔`main.version` check, scripts bundled | n/a |
| Documentation / governance | concern | README from-source path is false; STABILITY and audit-log frozen; no `hygiene.yaml`; no CODEOWNERS | n/a |

Do not aggregate these into a scalar.

## Findings

### ENT-001: Ingest orchestration is still an 851-line bash state machine behind a Go CLI

- **Priority:** P1
- **Dimensions:** Architecture topology; Change amplification; Local code quality
- **Status:** observed fact
- **Evidence:**
  - `scripts/playlist-ingest/ingest.sh` is 851 lines: cursors, `.processed`, fan-out, staleness, ISSUES/finish, network gate (`ingest.sh:38-70`, `648-851`).
  - `main.go:161-187` `exec`s that script; Go owns transcript, index, and synopsis only.
  - `ingest-one.sh` is 220 lines of download/analyze/throttle/mutex (`ingest-one.sh:83-112`, `114-211`).
  - bash.md boundary rule: state-with-invariants, concurrency, error taxonomy, structured data — this script owns all four.
  - History of the same class: 15-day silent channel no-op (config-from-prefix), `mapfile` on bash 3.2, Homebrew ytt treating `build-index` as a video ID (`ingest.sh:262-267`, 🎯T12/T16).
  - 🎯T7 (crosshair migration) is still `identified`.
- **Mechanism:** every ingest invariant lives in shell. A Go change (new subcommand) still requires a bash preflight, a plist pin, and bats. A bash change cannot reuse Go types or tests. Dual runtimes multiply “scripts vs binary” skew, the defect class that has already shipped.
- **Blast radius:** scheduled knowledge-base pipeline; Homebrew `ytt ingest`; any future cursor/queue/health change.
- **Counterevidence checked:** 48 ingest.bats + 9 ingest-one.bats pass; bash 3.2 CI job exists and asserts `/bin/bash` is 3.x (`.github/workflows/ci.yml:71-103`); ISSUES/finish is a single loud exit path (`ingest.sh:648-658`); download/analyze split (🎯T18) reduced coupled-run waste. This is a working, tested design — not an untested mess.
- **Smallest coherent remediation:** keep extracting *stateful* pieces into Go the way `build-index` and `synopsis` were extracted (queue/cursor/health), leaving bash as process glue; or land 🎯T7 when crosshair honors triggers. Do not rewrite ingest.sh in one shot.
- **Verification:** architecture test that `ytt ingest --help` is the only remaining bash entry, plus bats for cursor/health remaining on the Go side as they move.
- **Ratchet candidate:** CI job already syntax-checks `*.sh` under bash 3.2; add a line-count or “no new `mkdir` lock / cursor write in `*.sh`” attestation only after an extraction lands.

### ENT-002: Public install and runtime docs still describe the retired Python product

- **Priority:** P1
- **Dimensions:** Documentation / governance; Redundancy / sources of truth
- **Status:** observed fact
- **Evidence:**
  - `README.md:24-30` “From source / Requires Python 3.10+ / `pipx install git+https://github.com/marcelocantos/ytt`”. There are **zero** `*.py` files; `go.mod:3` is `go 1.26.1`.
  - `README.md:255-263` still says GitHub-release downloads “bundle their own interpreter” and ingest “optionally `claude` (npm)”.
  - `README.md:246-252` “the synopsis step also runs `claude` (Claude Code CLI)” and “plist pins both `ytt` and `claude`”. `ingest-one.sh:187-188` calls `"$YTT_BIN" synopsis`; plists pin `GROK_BIN`/`CLAUDE_BIN` for Claudia, not `YOUTUBE_INGEST_CLAUDE_BIN`.
  - `STABILITY.md:16` “Snapshot as of v0.5.0”; `STABILITY.md:120` lists `pipx install` as **Stable**; `STABILITY.md:133-139` claims only CLI smoke checks exist and `ingest-one.sh` shells out to `claude`.
  - `synopsis.go:287` prompt still calls the payload “the full youtube-transcript-api payload”.
- **Mechanism:** three documents (README, STABILITY, the synopsis prompt) assert a product that is not in this tree. A user following README from-source will not get a working install. An operator following the claude-npm paragraph will miss Claudia/Grok. 1.0 planning against STABILITY's gap list will re-do work that already landed.
- **Blast radius:** Homebrew-alternative installers; agents reading `--help-agent` vs README; 1.0 readiness judgments.
- **Counterevidence checked:** README subcommand table (`README.md:91-99`) *is* updated for `ingest --download/--analyze`, `build-index`, and `ytt synopsis`. `agents-guide.md:9-15` matches the Go CLI. The contradiction is the install/requirements/stability snapshot, not the whole README.
- **Smallest coherent remediation:** rewrite README Install/Requirements/Runtime dependencies to `go install` / release tarballs / Homebrew only; retitle STABILITY snapshot to current tag and strike pipx/pytest/`claude -p`; change the synopsis prompt's “youtube-transcript-api” wording.
- **Verification:** a docs test or CI step that `README.md` does not contain `pipx` / `Python 3.` / `youtube-transcript-api`, and that `STABILITY.md` does not claim pipx Stable.
- **Ratchet candidate:** `hygiene` file evidence `README.md` matches `go.mod` language; or a `rg` CI step on those strings.

### ENT-003: Declared local Go suite fails in the owner's workspace because Makefile ignores `GOWORK`

- **Priority:** P2
- **Dimensions:** Correctness / verification; Build / release / operations
- **Status:** observed fact
- **Evidence:**
  - `Makefile:16-17` `test-go: go test ./... -count=1 -race` (no `GOWORK=off`).
  - `Makefile:24-25` `vet: go vet ./...` likewise.
  - This run: `make test-go` exit 2, message `directory prefix . does not contain modules listed in go.work`.
  - Parent `/Users/marcelo/work/github.com/marcelocantos/go.work` lists only claudia and jevons.
  - Bullseye attestations for 🎯T16/T17/T18 all invoke `GOWORK=off go test ./...`.
- **Mechanism:** `go env GOWORK` walks to the parent workspace. `./...` then means “modules in the workspace”, not this repo. The Makefile target that CI conceptually mirrors is red on the machine that authors the code, so “run make test” is not an oracle here. CI remains green because Actions has no parent `go.work`.
- **Blast radius:** local false-red; agents/humans skipping the suite or exporting `GOWORK=off` by folklore.
- **Counterevidence checked:** `GOWORK=off go test ./... -count=1 -race` exit 0; CI `.github/workflows/ci.yml:25-26` is fine on a clean checkout. This is environment-conditioned, not a product bug.
- **Smallest coherent remediation:** `export GOWORK=off` at the top of the Makefile (or `GOWORK=off go test` on those recipes).
- **Verification:** `make test-go` exit 0 from this workspace without a manual env var.
- **Ratchet candidate:** Makefile recipe itself; `hygiene` `make_target: test-go` plus `command: make test-go` once it is GOWORK-safe.

### ENT-004: json3 subtitle parsing has no fixture; Fetch is only stubbed

- **Priority:** P2
- **Dimensions:** Correctness / verification
- **Status:** observed fact
- **Evidence:**
  - `transcript.go:186-214` is the json3 event → `Snippet` conversion (the load-bearing transcript transform).
  - Tests cover `findSubtitleFile` with empty `{}` files (`main_test.go:280-322`) and `Render`/`pyFloat` (`main_test.go:195-276`). No test unmarshals a real json3 `events` document.
  - `fetch` is a var so CLI tests stub it (`main.go:27-30`, `main_test.go:54-60`).
  - `STABILITY.md:140-142` still correctly names this gap (“canned-response fixture”).
- **Mechanism:** yt-dlp json3 shape drift (new event types, missing `tStartMs`, HTML entities in `utf8`) becomes empty text or `ErrNoTranscript` only in production. The Python-era silent-empty class (`transcript.go:19-26`) is guarded at “no file” / “no snippets”, not at “malformed-but-present events”.
- **Blast radius:** every `ytt <id>` and every ingest download.
- **Counterevidence checked:** `ErrNoTranscript` is distinct and tested (`main_test.go:175-191`, `296-301`). Human vs auto track preference is documented. Live YouTube is accepted residue, not a missing unit test of *our* parser.
- **Smallest coherent remediation:** commit one canned json3 file (human + ASR) and assert snippet text/start/duration plus `IsGenerated`.
- **Verification:** `go test` case that fails if the event loop skips `segs` text.
- **Ratchet candidate:** a `testdata/*.json3` fixture test in CI (already runs `go test`).

### ENT-005: Install-layout search, timeout wrapper, and ingest-root default are copied, not owned

- **Priority:** P2
- **Dimensions:** Redundancy / sources of truth; Change amplification
- **Status:** observed fact
- **Evidence:**
  - `ingestScript` (`main.go:189-212`) and `bundledPath` (`synopsis.go:322-341`) duplicate executable-relative search (`scripts/…` vs `../libexec/…`).
  - `with_timeout` copied in `ingest.sh:296-303` and `ingest-one.sh:66-73`; both fall through to **no timeout** when `timeout`/`gtimeout` are missing (`ingest.sh:294-295`).
  - Default root `~/think/knowledge/youtube` in `ingest.sh:119`, `ingest-one.sh:48`, and `index.go:67-74`.
- **Mechanism:** a third layout (e.g. `libexec` vs `share`) or a default-root 1.0 rename (`STABILITY.md:131-132`) must be edited in multiple languages. The silent no-timeout fallback is the exact GNU/BSD trap bash.md names: missing coreutils converts the watchdog into a no-op (release.yml comments already record this for Homebrew).
- **Blast radius:** packaged `ytt ingest` / `ytt synopsis`; scheduled watchdog; anyone running from source without coreutils.
- **Counterevidence checked:** Homebrew formula `depends_on: coreutils` (`.github/workflows/release.yml:108-121`); macOS CI installs coreutils and uses it (`.github/workflows/ci.yml:76-87`). Source/manual path is the hole. `bundledPath` is the generalized form; `ingestScript` could call it.
- **Smallest coherent remediation:** `ingestScript` → `bundledPath("scripts","playlist-ingest","ingest.sh")`; one default-root constant/env helper; log-and-die (or `die`) when `TIMEOUT_BIN` is empty instead of silently running.
- **Verification:** bats already has a watchdog test (`ingest.bats:131-141`); add a case that a missing timeout binary is loud. Go test that both scripts resolve from a fake libexec tree via one helper.
- **Ratchet candidate:** `command -v timeout || command -v gtimeout` asserted in ingest preflight; grep gate against a second `with_timeout` definition.

### ENT-006: Default synopsis provider (Grok) does not strip write/shell tools on untrusted transcripts

- **Priority:** P2
- **Dimensions:** Security / dependencies
- **Status:** observed fact (mitigations documented as residual)
- **Evidence:**
  - `synopsis.go:353-361`: `DisallowTools` is set only for `ProviderClaude`; Codex gets `workspace-write` + `never`; **Grok has neither**.
  - Default ladder is Grok first (`synopsis.go:25`, `synopsis.go:92-98`).
  - Comment at `synopsis.go:355-356`: “Transcript is untrusted input.”
  - 🎯T17 attestation already records: “Grok Task still cannot honour DisallowTools (claudia T23 fail-closed); untrusted-transcript writes rely on stdout + CWD.”
  - Host still writes the file from stdout (`synopsis.go:82-88`, prompt “Do not write any files”).
- **Mechanism:** a prompt-injected transcript can ask Grok to write/exec in `WorkDir` (the video directory under the knowledge tree). Claude is hardened; the default provider is not.
- **Blast radius:** every analyze-tick synopsis while Grok is first; files under `$YOUTUBE_INGEST_ROOT/<id>/`.
- **Counterevidence checked:** host-side write + “do not write files” prompt; Claude strip; Codex sandbox; 🎯T17 names this as accepted residue pending claudia. Not a new hole, but it is still the default path.
- **Smallest coherent remediation:** fail-closed for Grok until claudia T23, or put Claude/Codex first when Grok cannot honour tool policy; keep host-only writes.
- **Verification:** a Claudia/ytt test that a Grok task config either sets DisallowTools or refuses to run.
- **Ratchet candidate:** unit assertion on `runClaudiaProvider` config per provider; blocked on claudia.

### ENT-007: One direct module (`claudia`) imports a large unrelated graph with no scan

- **Priority:** P2
- **Dimensions:** Security / dependencies
- **Status:** observed fact
- **Evidence:**
  - `go.mod` direct require is only claudia; `go list -m all` includes `aws-sdk-go-v2`, `bedrockruntime`, `modernc.org/sqlite`, `quic-go`, `certmagic`, `github.com/marcelocantos/jevons`, …
  - No `.github/dependabot.yml`, no CodeQL/govulncheck/secret-scan workflow.
  - Transcript path does not need this graph; synopsis does.
- **Mechanism:** a vulnerability or API break in Bedrock/quic/sqlite becomes ytt's supply chain even though ytt is a yt-dlp CLI. There is no scheduled refresh or advisory gate.
- **Blast radius:** `go build` of ytt; release binaries.
- **Counterevidence checked:** pinning via `go.sum`; claudia is an owned module. Proportionate for a personal CLI, but the graph is disproportionate to the transcript feature.
- **Smallest coherent remediation:** `govulncheck` in CI; optionally a build tag / slimmer claudia client if one exists. Do not vendor.
- **Verification:** CI job `govulncheck ./...` exit 0.
- **Ratchet candidate:** hygiene `scanner: {tool: govulncheck, invoked: ci}` when hygiene is declared.

### ENT-008: Dead notifier/claude-era test doubles remain on PATH for bats

- **Priority:** P3
- **Dimensions:** Redundancy / sources of truth
- **Status:** observed fact
- **Evidence:**
  - `scripts/playlist-ingest/tests/mocks/claude` and `mocks/terminal-notifier` are tracked.
  - No bats/lib.bash reference to `terminal-notifier`. Synopsis failure injection now lives in `mocks/ytt` (`MOCK_CLAUDE_*` knobs, `tests/mocks/ytt:17-67`).
  - `lib.bash:4` comment still lists `claude` / `build-index.sh` as stubbed.
- **Mechanism:** PATH-prepending unused mocks invites a future test to hit the old `claude -p` contract. The curl mock still implements Slack webhook POST (`mocks/curl:10-51`) for deleted `notify.sh`.
- **Blast radius:** ingest bats only.
- **Counterevidence checked:** unused files cannot change production. `MOCK_CLAUDE_*` names are living API for the ytt mock.
- **Smallest coherent remediation:** delete `mocks/claude` and `mocks/terminal-notifier`; trim curl's webhook branch if no test reads `MOCK_CURL_POST_LOG`.
- **Verification:** `rg terminal-notifier|mocks/claude` empty; bats still 62/62.
- **Ratchet candidate:** none until deleted.

### ENT-009: Stability, audit-log, and achieved-target text are frozen on the Python product

- **Priority:** P3
- **Dimensions:** Documentation / governance
- **Status:** observed fact
- **Evidence:**
  - `docs/audit-log.md` last entry is v0.5.0 (2026-04-28); Go port is `a2e15a6` / v0.11.0.
  - 🎯T9 acceptance still requires a pytest suite (`bullseye.yaml` T9); status `achieved` from the Python era.
  - 🎯T2/T13 context still names `ytt.py`, `notify.sh`, `build-index.sh`.
- **Mechanism:** historical targets are immutable *as history*, but STABILITY's 1.0 gap list and the audit log are still used as planning surfaces. They understate verification and overstate Python distribution.
- **Blast radius:** 1.0 planning; newcomers reading `docs/`.
- **Counterevidence checked:** bullseye achieved text is a record, not a live contract. ENT-002 already covers user-facing README. This finding is the governance freeze, not the install-path failure.
- **Smallest coherent remediation:** append an audit-log entry for the Go port; rewrite STABILITY gaps against today's tests; leave achieved bullseye rows, fix only if a target is reopened.
- **Verification:** audit-log mentions Go/`ytt synopsis`; STABILITY test-coverage bullet is gone or inverted.
- **Ratchet candidate:** none (prose).

### ENT-010: Version-controlled launchd plists are a live personal machine config

- **Priority:** P3
- **Dimensions:** Build / release / operations; Documentation / governance
- **Status:** observed fact (deliberate exception with residue)
- **Evidence:**
  - `scripts/playlist-ingest/launchd/com.marcelocantos.youtube-ingest.plist:49-75` hard-codes `/Users/marcelo/.local/bin/ytt`, a personal playlist URL, `GROK_BIN`/`CLAUDE_BIN`, blurter under `/opt/homebrew`.
  - README (`README.md:164-176`) says edit paths first; 🎯T7.1 required committing the live plist to kill binary-identity skew.
- **Mechanism:** `cp` of the bundled plist onto another Mac points at this owner's binaries and playlist. The playlist ID is not a secret but is personal. Docs and the file disagree on whether this is a template or the production scheduler.
- **Blast radius:** anyone installing from the repo's `launchd/` directory.
- **Counterevidence checked:** T7.1 / comments in the plist explain why pins are absolute. This is accepted personal-tool shape, not an accidental leak of credentials (no tokens in-tree).
- **Smallest coherent remediation:** keep pins, replace the playlist URL with a placeholder in the tracked copy, or ship `*.plist.example` and gitignore the live one.
- **Verification:** tracked plist has no `list=PL…` personal ID (if example-ized).
- **Ratchet candidate:** none until T7 retires launchd.

## Redundancy and competing-source-of-truth inventory

| Concept | Owners | Drift already? | Action |
|---|---|---|---|
| Synopsis format | `synopsis-contract.md` (declared SoT); `index.go` parser; `ytt synopsis` prompt | Prompt still says youtube-transcript-api (`synopsis.go:287`); parser and contract match (bats + Go tests) | Keep contract; fix prompt wording |
| Install language | `go.mod` / README Homebrew / README pipx / STABILITY pipx | **Yes** (ENT-002) | Delete Python install path |
| Ingest root default | ingest.sh, ingest-one.sh, index.go, README, STABILITY | Same string today | One helper before 1.0 rename |
| Bundled-file resolution | `ingestScript`, `bundledPath` | Not yet | Dedup (ENT-005) |
| Timeouts | two `with_timeout` copies; formula `coreutils` | Fallback is silent | Fail loud (ENT-005) |
| Synopsis invocation | `ingest-one.sh` → `ytt synopsis`; README `claude` npm; dead `mocks/claude` | **Yes** | ENT-002, ENT-008 |
| Alerting | blurter (code); T11/T13 acceptance still describes Slack DM / notify.sh / terminal-notifier | Historical target text only | Leave achieved rows; delete dead mocks |
| `download_complete` | ingest.sh (arg = id) vs ingest-one.sh (uses `$DIR`) | Same predicate | Acceptable duplication across process boundary |
| Version | `main.go:22` `0.11.0`; Makefile `git describe`; release.yml greps `main.go` | Branch is unreleased work still labeled 0.11.0 | Release skill owns the bump |

Deliberate duplication worth keeping: Python-compatible JSON (`pyFloat`) so `--json` consumers do not see a language-change diff; bats black-box of `ytt build-index` *and* Go unit tests of `extractTLDR` (different layers).

## Healthy structure worth retaining

- **Distinct `ErrNoTranscript`** (`transcript.go:19-26`, `212-214`) — refuses to turn “no captions” into an empty transcript. Tested.
- **Synopsis contract file** as the only format spec (`synopsis-contract.md` header). 🎯T8.
- **User-config-first channels path** plus orphaned-config failure (`ingest.sh:28-36`, `144-155`; bats “orphaned channels config”).
- **Single ISSUES → notify → finish path** (`ingest.sh:201-250`, `648-658`) so an unhealthy run cannot exit quiet. blurter is side-channel and cannot change rc.
- **bash 3.2 CI with an actual version assert** (`.github/workflows/ci.yml:88-92`) — the standing oracle bash.md asks for.
- **Preflight that `ytt --help` advertises `build-index` and `synopsis`** (`ingest.sh:268-275`; bats 15–16) — closes the Homebrew-Python skew.
- **Download/analyze split** with batch cap and “remainder is not failure” (🎯T18; bats 44–47).
- **Release tag must match `main.version`** (`.github/workflows/release.yml:37-47`).
- **Go API shape:** `FetchArgs` struct, not functional options (`transcript.go:72-80`), matching `go.md`.
- **Host writes synopsis files**; agents are told not to (`synopsis.go:82-88`, prompt). Keep this even if Grok tools stay weak.

## Hygiene posture

**Hygiene posture not declared.** No `hygiene.yaml` at repo root. Per the hygiene skill, it was not initialized.

Informal observation (not a validator report): CI encodes gofmt, vet, `go test -race`, build, CLI smoke, bats, and bash 3.2. LICENSE Apache-2.0, README, `.gitignore` exist. Missing relative to a typical tier-2 posture: secret scan, vuln scan, CODEOWNERS, dependabot, `hygiene.yaml` itself.

Overlap with entropy: ENT-003/ENT-007 are the items that would become hygiene `command` / `scanner` evidence once a file is authored.

## Oracle coverage and residue

| Property | Decided by | Notes |
|---|---|---|
| CLI flags, exit codes, ID extract, render, pyFloat JSON | Shipped: `go test` | Hermetic |
| json3 event parsing | **Nothing** | ENT-004 |
| Live yt-dlp / YouTube captions | Accepted risk / manual | CI must not hit YouTube |
| Cursor protocol, orphan sweep, queue, staleness, alerts, download/analyze | Shipped: 62 bats | This audit ran them on bash 5.3; CI also runs bash 3.2 |
| `ytt build-index` table/TL;DR/Caveat | Shipped: Go tests + build-index.bats | |
| Synopsis ladder (capacity, skip missing, write file) | Shipped: `synopsis_test.go` with stubbed `runSynopsisProvider` | |
| Live Claudia grok/claude/codex | **Nothing in CI** | 🎯T17 residual; live plist is the operational path |
| Grok tool policy | Manual / claudia T23 | ENT-006 |
| bash 3.2 syntax + bats | Shipped: CI `scripts-bash32` | Not re-run here (no macOS runner) |
| `make test-go` in this workspace | **Fails** | ENT-003 |
| Release tag = `main.version` | Shipped: release.yml | Not exercised this run |
| Homebrew formula deps | release.yml `depends_on` | Actual tap formula not opened |
| From-source pipx install | Docs only, **false** | ENT-002 |
| Secrets in repo | Manual grep / gitignore | `channels.yaml` gitignored; plists have no tokens |

**Owner-residue (intent only):**

1. Keep `~/think/knowledge/youtube` as default until 1.0, or change now?
2. Tracked launchd plists: live pins vs example files (🎯T7 vs T7.1)?
3. Accept Grok-without-DisallowTools until claudia T23, or reorder the ladder?
4. Declare `hygiene.yaml` (this audit will not)?

Mechanical work (fixtures, Makefile `GOWORK=off`, README) is **not** owner-residue.

## Remediation sequence

1. **Oracle seam:** `export GOWORK=off` in the Makefile so `make test` is a real local gate (ENT-003). Add a canned json3 fixture test (ENT-004).
2. **Competing truths:** fix README install/requirements and STABILITY snapshot/gaps; drop pipx/Python/`claude -p` (ENT-002). Append audit-log for the Go port (ENT-009).
3. **Boundary ownership:** `bundledPath` as the only layout search; fail if `timeout`/`gtimeout` missing; one ingest-root default (ENT-005). Delete dead mocks (ENT-008).
4. **Do not rewrite ingest.sh yet.** Extract the next stateful slice (cursor or health) only with bats staying green; 🎯T7 remains the scheduler end-state (ENT-001).
5. **Security:** keep host-only synopsis writes; track claudia T23 for Grok tools (ENT-006); add `govulncheck` when hygiene is declared (ENT-007).
6. **Ratchet** the accepted properties in CI, then `hygiene.yaml` if the owner asks.
7. Re-run this audit on the same definitions.

No architectural rewrite is required to close ENT-002/003/004/005/008; ENT-001 is sequencing, not a green-field ingest.
