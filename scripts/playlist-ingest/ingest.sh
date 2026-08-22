#!/usr/bin/env bash
# Ingest new videos from a YouTube playlist and from tracked channels.
#
# Usage: ingest.sh [--dry-run] [--download|--analyze] [PLAYLIST_URL]
#   PLAYLIST_URL defaults to $YOUTUBE_INGEST_PLAYLIST and must be an
#   http(s) URL, except for --analyze (disk scan only). -h/--help prints
#   this header.
#   --download  paced YouTube fetch only: transcript.json + meta.json.
#               Bounded per tick ($YOUTUBE_INGEST_DOWNLOAD_BATCH, default
#               16). Does not write synopses or .processed.
#   --analyze   unthrottled synopsis of every on-disk download that is
#               not yet in .processed. No YouTube discovery.
#   neither     download tick, then analyze tick (two fan-outs).
#   --dry-run   discovery + pending-analyze scan; prints the queues;
#               touches nothing.
#
# Sources:
#   1. The playlist named by PLAYLIST_URL / $YOUTUBE_INGEST_PLAYLIST.
#   2. The channels listed in the resolved channels file — $YOUTUBE_CHANNELS_FILE
#      if set, else $XDG_CONFIG_HOME/ytt/channels.yaml (i.e. normally
#      ~/.config/ytt/channels.yaml), else the copy beside this script.
#   3. A persistent extra-ID file ($YOUTUBE_INGEST_QUEUE, default
#      $STATE_DIR/backfill.ids). One video ID per line; comments (#) and
#      blanks skipped. Deduped against .processed each run, so this is the
#      backfill hopper: drop IDs here and the existing paced workers drain
#      them. The file is not rewritten — .processed is the drain cursor.
#
# Config location: the channels file must NOT be resolved from the install
# directory alone. This script is installed into a versioned, package-managed
# prefix (Homebrew: .../Cellar/ytt/<version>/libexec/...) which is replaced
# wholesale on upgrade and never contains the user's gitignored channels.yaml.
# Resolving config from $HERE silently disabled channel ingest for 15 days
# (2026-07-10 → 07-26) the moment the scheduler was pinned to the installed
# binary: the run found no channels file, logged it as "not enabled", and
# exited 0 every night. Hence the user-config-first search order above, and
# the orphaned-config check further down.
#
# All sources share $ROOT/.processed for dedup. For channels, a per-channel
# cursor file at $ROOT/.channels/<handle> records the most recent video ID
# from this channel that's landed in .processed — no backfill of older
# uploads beyond the cursor.
#
# Cursor invariant: a cursor file should ALWAYS name an ID present in
# .processed. The cursor advances after the worker pool drains, walking
# this run's discoveries oldest-first and stopping at the first ID that
# didn't land. Failed ingests stay above the cursor and get retried next
# run. If a stale cursor is encountered (not in .processed — a relic of
# an older speculative-advance bug), it is distrusted and the walk
# proceeds past it, bounded by a safety limit.
#
# Concurrency: $YOUTUBE_INGEST_CONCURRENCY (default 4).
# Queue file:  $YOUTUBE_INGEST_QUEUE    (default $STATE_DIR/backfill.ids)
# Output:      $YOUTUBE_INGEST_ROOT     (default ~/think/knowledge/youtube)
# Network:     the run waits for connectivity before discovery — the daily
#              launchd tick usually fires in a DarkWake maintenance window
#              with no Wi-Fi, where every DNS lookup fails.
#              $YOUTUBE_INGEST_NETWORK_WAIT caps the wait (default 14400s);
#              $YOUTUBE_INGEST_NETWORK_POLL sets the poll interval (default 60s).
# Alerts:      an unhealthy run reports a one-line verdict plus the offending
#              log lines to `blurter send`, which spools the event; the blurter
#              daemon owns delivery (Slack DM, desktop banner), dedup and
#              recovery notices. Nobody reads a log file daily, so a scheduled
#              job that can only complain into its own log is a job that fails
#              silently. blurter is a hard dependency; see its README for
#              configuration.
# Staleness:   a run is also unhealthy if channels are tracked but NOTHING has
#              been ingested for $YOUTUBE_INGEST_STALE_DAYS days (default 7,
#              0 disables). This is the backstop for the whole "every step
#              reported success and yet no knowledge arrived" failure class —
#              the one that survived every other check in this pipeline.

set -euo pipefail

case "${1:-}" in
    -h|--help)
        # The header comment doubles as the usage text.
        awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "$0"
        exit 0
        ;;
esac

DRY_RUN=false
STAGE=all
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --download)
            if [[ "$STAGE" == analyze ]]; then STAGE=all; else STAGE=download; fi
            shift
            ;;
        --analyze)
            if [[ "$STAGE" == download ]]; then STAGE=all; else STAGE=analyze; fi
            shift
            ;;
        *) break ;;
    esac
done

PLAYLIST="${1:-${YOUTUBE_INGEST_PLAYLIST:-}}"
if [[ "$STAGE" != analyze && -z "$PLAYLIST" ]]; then
    echo "error: playlist URL required (arg or \$YOUTUBE_INGEST_PLAYLIST)" >&2
    exit 2
fi
# Anything that isn't an http(s) URL — a stray flag, a bare word — must never
# reach yt-dlp as the playlist: `ingest.sh --help` once became
# playlist="--help", yt-dlp printed its own help text, and 851 lines of usage
# output were queued as "video IDs" for ingest.
if [[ "$STAGE" != analyze ]]; then
    # Anything that isn't an http(s) URL — a stray flag, a bare word — must never
    # reach yt-dlp as the playlist: `ingest.sh --help` once became
    # playlist="--help", yt-dlp printed its own help text, and 851 lines of usage
    # output were queued as "video IDs" for ingest.
    if [[ "$PLAYLIST" != http://* && "$PLAYLIST" != https://* ]]; then
        echo "error: playlist must be an http(s) URL, got: $PLAYLIST" >&2
        exit 2
    fi
fi

ROOT="${YOUTUBE_INGEST_ROOT:-$HOME/think/knowledge/youtube}"
STATE="$ROOT/.processed"
FAILED_IDS="$ROOT/.download-failed"
# Log defaults into the content tree for manual use; the scheduled runner
# points $YOUTUBE_INGEST_LOG outside it so scheduled churn doesn't commit.
LOG="${YOUTUBE_INGEST_LOG:-$ROOT/.ingest.log}"
CHANNELS_DIR="$ROOT/.channels"
CONCURRENCY="${YOUTUBE_INGEST_CONCURRENCY:-4}"
ANALYZE_CONCURRENCY="${YOUTUBE_INGEST_ANALYZE_CONCURRENCY:-$CONCURRENCY}"
# Per-tick download cap so a 9k hopper cannot pin launchd for six hours
# and skip every later tick. 16 IDs at 3–7 min pacing with 4 workers is
# about one 20-minute StartInterval. 0 disables the cap.
DOWNLOAD_BATCH="${YOUTUBE_INGEST_DOWNLOAD_BATCH:-16}"
# Run-level watchdog: a hard cap on the whole fan-out. The per-call timeouts
# stop any single network/LLM call hanging, but this bounds the run AS A WHOLE
# so no other failure mode — a stuck worker the timeouts miss, a wedged loop,
# or simply a backlog so large the 3–7 min pacing (stretched by laptop sleep)
# runs for many hours — can keep the run, and thus every future launchd tick
# (launchd starts no concurrent instances), alive indefinitely. On expiry the
# fan-out is killed; unfinished videos retry next run. 0 disables the cap.
RUN_TIMEOUT="${YOUTUBE_INGEST_RUN_TIMEOUT:-21600}"   # 6 hours
# Safety limit on how deep into a channel feed we'll walk in one run.
# Bounds the worst case when a cursor is stale or missing.
CHANNEL_WALK_LIMIT=50
HERE="$(cd "$(dirname "$0")" && pwd)"

# Resolve the channels file from user config first and the install dir last —
# see the "Config location" note in the header for why the reverse order cost
# 15 days of silent no-ops. An explicit $YOUTUBE_CHANNELS_FILE always wins
# (the scheduler pins it; the tests rely on it).
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ytt"
if [[ -n "${YOUTUBE_CHANNELS_FILE:-}" ]]; then
    CHANNELS_FILE="$YOUTUBE_CHANNELS_FILE"
elif [[ -f "$CONFIG_DIR/channels.yaml" ]]; then
    CHANNELS_FILE="$CONFIG_DIR/channels.yaml"
else
    CHANNELS_FILE="$HERE/channels.yaml"
fi

# Alert/notification state lives outside $ROOT: $ROOT is a git-tracked content
# tree, and health bookkeeping is machine state, not knowledge.
STATE_DIR="${YOUTUBE_INGEST_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ytt}"
STALE_DAYS="${YOUTUBE_INGEST_STALE_DAYS:-7}"
# Notification is blurter's job, not ours. ytt reports events; blurter owns the
# credential, the delivery policy (dedup, re-notify windows, recovery notices)
# and the sinks. This is a hard dependency, declared by the Homebrew formula:
# keeping a private fallback notifier would preserve exactly the duplicated,
# subtly-wrong delivery logic that moving to blurter removes, and the fallback
# is the path that would run when it mattered.
BLURTER_BIN="${YOUTUBE_INGEST_BLURTER_BIN:-blurter}"

export YOUTUBE_INGEST_ROOT="$ROOT"

mkdir -p "$ROOT" "$CHANNELS_DIR" "$STATE_DIR"
touch "$STATE" "$FAILED_IDS" "$LOG"

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG" >&2
}

# A download is complete when both the transcript payload and metadata
# are non-empty. Analysis (synopsis + .processed) is a later, independent
# stage; this helper must not look at .processed.
download_complete() {
    local d="$ROOT/$1"
    [[ -s "$d/.transcript/transcript.json" && -s "$d/meta.json" ]]
}

download_rejected() {
    grep -Fxq -- "$1" "$FAILED_IDS" 2>/dev/null
}

# IDs on disk that have a complete download and are not yet in .processed.
collect_pending_analyze() {
    PENDING_ANALYZE=()
    shopt -s nullglob
    local dir id
    for dir in "$ROOT"/*/; do
        id="$(basename "$dir")"
        [[ "$id" =~ ^[A-Za-z0-9_-]{11}$ ]] || continue
        grep -Fxq -- "$id" "$STATE" && continue
        download_complete "$id" || continue
        PENDING_ANALYZE+=("$id")
    done
    shopt -u nullglob
}

# Everything wrong with this run, one human-readable line per problem. This
# list is BOTH the exit-code decision and the notification body, so there is
# no way to add a failure mode that fails the run without also alerting.
ISSUES=()
note_issue() {
    ISSUES+=("$*")
    log "UNHEALTHY: $*"
}

# Report a verdict to blurter. Alerting is a side channel: a notification
# problem must never change the run's outcome, so failures here are logged and
# swallowed rather than propagated.
#
# `blurter send` writes an event to a spool and exits, so this neither blocks on
# the network nor needs a credential, and an alert raised while the machine is
# offline is still delivered later. Exit 0 means spooled, not delivered.
notify() {
    local severity="$1" subject="$2"; shift 2
    if $DRY_RUN; then
        # A diagnostic run must not page anyone, and must not touch blurter's
        # dedup state — otherwise debugging suppresses the real alert that the
        # next scheduled run needs to send.
        log "dry run: would report [$severity] $subject"
        return 0
    fi
    if ! command -v "$BLURTER_BIN" >/dev/null; then
        log "blurter not found on PATH ($BLURTER_BIN); alert not reported"
        return 0
    fi
    # --link points blurter's notification click action at this run's log.
    # --key collapses repeats: the counts in $subject vary run to run while the
    # underlying problem does not, and blurter would otherwise treat every run
    # as a fresh problem and alert nightly.
    # SC2094: --link only passes $LOG's path as an argument; nothing reads the
    # file here, so writing to it in the same pipeline is safe.
    # shellcheck disable=SC2094
    if ! printf '%s\n' "$@" \
            | "$BLURTER_BIN" send --app ytt --severity "$severity" \
                --subject "$subject" --body - --key "ytt-ingest-$severity" \
                --link "$LOG" --quiet >>"$LOG" 2>&1; then
        log "reporting to blurter failed (see $LOG); continuing"
    fi
}

# Preflight aborts exit before the run proper, so they alert on their way out.
die() {
    note_issue "$1"
    notify problem "ytt ingest aborted before discovery" "${ISSUES[@]}"
    exit 1
}

# Resolve the ytt executable which identifies the ingest pipeline before
# doing network discovery or creating per-video state. launchd deliberately
# starts with a minimal PATH, so leaving the lookup to a worker turns a
# missing dependency into a misleading, apparently-successful empty run.
# Synopses go through `ytt synopsis` (Claudia); grok/claude/codex are
# resolved by Claudia itself, not by this script.
YTT_BIN="${YOUTUBE_INGEST_YTT_BIN:-ytt}"
if ! YTT_BIN="$(command -v "$YTT_BIN")"; then
    die "ytt executable not found: ${YOUTUBE_INGEST_YTT_BIN:-ytt}; aborting"
fi
# ingest.sh calls `$YTT_BIN build-index` after a successful pass. A binary
# that does not implement that subcommand (Homebrew 0.11.0 is still the
# Python CLI) treats the token as a video ID, fetches it, and reports
# `ytt: build-index: VideoUnavailable` — three nights of UNHEALTHY index
# refresh after real ingest (2026-08-16 → 08-19). Fail here, before
# discovery, so the skew cannot hide behind hours of paced workers.
ytt_help_has() {
    local needle="$1" n=0
    # A `go build -o ytt` can replace this file mid-tick and make --help
    # empty for a moment. Retry once before treating it as the old
    # Homebrew-Python skew.
    while (( n < 2 )); do
        if "$YTT_BIN" --help 2>&1 | grep -q "$needle"; then
            return 0
        fi
        n=$((n + 1))
        sleep 1
    done
    return 1
}
if [[ "$STAGE" != download ]]; then
    if ! ytt_help_has 'build-index'; then
        die "ytt at $YTT_BIN does not implement build-index (the ingest scripts require it); aborting"
    fi
    if ! ytt_help_has 'synopsis'; then
        die "ytt at $YTT_BIN does not implement synopsis (the ingest scripts require it); aborting"
    fi
fi
export YOUTUBE_INGEST_YTT_BIN="$YTT_BIN"

# --- bash 3.2 compatibility ------------------------------------------------
# macOS ships bash 3.2.57 (Apple froze it at the last GPLv2 release) and this
# script is distributed to macOS users, so it must not use bash 4+ features.
# Two traps, both of which used to break `ytt ingest` outright on a stock Mac:
#
#   1. `mapfile`/`readarray` do not exist. Reading a stream into an array is
#      spelled as a `while IFS= read -r` loop below. The `|| [[ -n "$_line" ]]`
#      tail matters: it keeps a final line that lacks a trailing newline, which
#      is what mapfile did.
#   2. Under `set -u`, bash before 4.4 treats "${arr[@]}" on an EMPTY array as
#      an unbound variable and aborts. Every expansion of an array that can
#      legitimately be empty is therefore written ${arr[@]+"${arr[@]}"}.
#
# Hard-timeout wrapper for the yt-dlp discovery calls below — a stalled
# connection (e.g. after the laptop sleeps mid-run) must not wedge the run.
# macOS lacks GNU timeout; Homebrew coreutils ships it as `timeout`/`gtimeout`.
# Falls back to no timeout only if neither exists.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
with_timeout() {
    local secs="$1"; shift
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" --kill-after=10 "$secs" "$@"
    else
        "$@"
    fi
}

log "playlist=$PLAYLIST root=$ROOT concurrency=$CONCURRENCY"

# Wait for network before any discovery. The daily launchd tick usually fires
# while the laptop sleeps: launchd defers it to the next wake, which is often
# a DarkWake maintenance window with no Wi-Fi association — every DNS lookup
# fails, and (worse) a failed feed fetch is indistinguishable from an empty
# one. Rather than run blind, park here until connectivity appears; the run
# effectively defers until the machine properly wakes. The wait counts
# awake-time only (sleep(1) doesn't tick while the machine sleeps) and is
# bounded so a network that never returns gives up loudly, leaving the retry
# to the next scheduled run.
NETWORK_WAIT="${YOUTUBE_INGEST_NETWORK_WAIT:-14400}"   # 4 hours
NETWORK_POLL="${YOUTUBE_INGEST_NETWORK_POLL:-60}"
(( NETWORK_POLL > 0 )) || NETWORK_POLL=1
# Without this preflight, a missing curl exits 127 inside network_up and the
# gate loops for the full NETWORK_WAIT looking exactly like a network outage.
if ! command -v curl >/dev/null; then
    die "curl not found on PATH — cannot probe network reachability; aborting"
fi
network_up() {
    curl -fsI --max-time 10 -o /dev/null https://www.youtube.com/robots.txt
}
WAITED=0
until network_up; do
    if (( WAITED >= NETWORK_WAIT )); then
        die "network still unreachable after ${WAITED}s of waiting; giving up (next scheduled run retries)"
    fi
    if (( WAITED == 0 )); then
        log "network unreachable; waiting up to ${NETWORK_WAIT}s for connectivity"
    fi
    sleep "$NETWORK_POLL"
    WAITED=$((WAITED + NETWORK_POLL))
done
if (( WAITED > 0 )); then
    log "network up after ${WAITED}s; proceeding"
fi

# Every discovery source that fails (as opposed to legitimately coming back
# empty) bumps this. Failures must be loud: a run that discovered nothing
# because the network dropped is NOT a run that found nothing new.
DISCOVERY_FAILURES=0

# Heal incomplete downloads from previous failed runs. A dir with both
# transcript.json and meta.json is pending analysis, not an orphan.
# --analyze must not sweep at all: it overlaps the download job, and
# wiping a dir that is only waiting on the 3–7 min throttle makes the
# worker fail with "transcript.raw.json: No such file or directory".
# Download-stage sweep also skips dirs newer than ORPHAN_MIN minutes so
# a slow in-flight fetch is not reclaimed mid-pacing.
ORPHAN_MIN="${YOUTUBE_INGEST_ORPHAN_MIN:-60}"
ORPHAN_NEW=()
if [[ "$STAGE" != analyze ]]; then
    shopt -s nullglob
    for dir in "$ROOT"/*/; do
        id="$(basename "$dir")"
        grep -Fxq -- "$id" "$STATE" && continue
        download_complete "$id" && continue
        download_rejected "$id" && { $DRY_RUN || rm -rf "$dir"; continue; }
        if (( ORPHAN_MIN > 0 )) && find "$dir" -maxdepth 0 -mmin -"$ORPHAN_MIN" 2>/dev/null | grep -q .; then
            continue
        fi
        ORPHAN_NEW+=("$id")
        $DRY_RUN || rm -rf "$dir"
    done
    shopt -u nullglob
fi

if (( ${#ORPHAN_NEW[@]} > 0 )); then
    log "orphan dirs from failed prior runs (queued for retry): ${ORPHAN_NEW[*]}"
fi

PLAYLIST_PENDING=""
QUEUE_PENDING=""
NEW=()
if [[ "$STAGE" == analyze ]]; then
    log "analyze-only: skipping YouTube discovery (disk scan follows)"
fi

# Collect new IDs from the playlist.
if [[ "$STAGE" != analyze ]]; then
PLAYLIST_IDS=()
PLAYLIST_LIST="$(mktemp)"
if with_timeout 120 yt-dlp --flat-playlist --print id --playlist-reverse "$PLAYLIST" >"$PLAYLIST_LIST"; then
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        PLAYLIST_IDS+=("$_line")
    done <"$PLAYLIST_LIST"
else
    rc=$?
    DISCOVERY_FAILURES=$((DISCOVERY_FAILURES + 1))
    note_issue "playlist enumeration FAILED (rc=$rc); playlist skipped this run"
fi
rm -f "$PLAYLIST_LIST"

PLAYLIST_NEW=()
for ID in ${PLAYLIST_IDS[@]+"${PLAYLIST_IDS[@]}"}; do
    grep -Fxq -- "$ID" "$STATE" || PLAYLIST_NEW+=("$ID")
done
log "playlist=${#PLAYLIST_IDS[@]} pending=${#PLAYLIST_NEW[@]}"

# Persistent extra-ID hopper (Takeout backfill, one-shot dumps). Same
# contract as the playlist: re-read every run, skip anything already in
# .processed. Missing file ⇒ source not enabled, not an error.
QUEUE="${YOUTUBE_INGEST_QUEUE:-$STATE_DIR/backfill.ids}"
QUEUE_NEW=()
if [[ -f "$QUEUE" ]]; then
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _line="${_line%%#*}"
        _line="${_line#"${_line%%[![:space:]]*}"}"
        _line="${_line%"${_line##*[![:space:]]}"}"
        [[ -n "$_line" ]] || continue
        grep -Fxq -- "$_line" "$STATE" && continue
        QUEUE_NEW+=("$_line")
    done < "$QUEUE"
    log "queue=$QUEUE pending=${#QUEUE_NEW[@]}"
fi

# Collect new IDs from each tracked channel.
#   Bootstrap (no cursor): take the latest upload. If already in .processed,
#     adopt it as the cursor immediately. Otherwise queue it and DEFER the
#     cursor write — it'll be set by the post-fan-out step iff ingest lands.
#   Steady state: walk newest-first; stop at cursor IF the cursor is in
#     .processed (trusted). If the cursor isn't in .processed it's a relic
#     of an older bug — walk past it (bounded by CHANNEL_WALK_LIMIT) and
#     dedup against .processed; the post-fan-out step writes a real cursor.
#   In both cases, the per-channel discovery list is recorded to
#   $CHANNELS_DIR/<handle>.discovered, which feeds both the round-robin
#   fan-out ordering below and the post-fan-out cursor advance.
if [[ -f "$CHANNELS_FILE" ]]; then
    HANDLES=()
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        HANDLES+=("$_line")
    done < <(yq -r '.channels[].handle' "$CHANNELS_FILE")
    for handle in ${HANDLES[@]+"${HANDLES[@]}"}; do
        handle="${handle#@}"
        [[ -n "$handle" ]] || continue
        # Takeout (and the Data API) identify channels by UC… id, not
        # @handle. Resolving thousands of handles would be its own YouTube
        # burst; accept the id as the handle and hit /channel/UC…/videos.
        if [[ "$handle" =~ ^UC[A-Za-z0-9_-]{22}$ ]]; then
            url="https://www.youtube.com/channel/${handle}/videos"
        else
            url="https://www.youtube.com/@${handle}/videos"
        fi
        marker="$CHANNELS_DIR/$handle"
        discovered="$CHANNELS_DIR/$handle.discovered"

        if [[ ! -f "$marker" ]]; then
            # The `|| rc=$?` guard matters: a bare `latest=$(...)` assignment
            # under `set -e` aborts the WHOLE RUN when the fetch fails — one
            # new channel added while the network was down used to kill every
            # scheduled run at bootstrap.
            rc=0
            latest=$(with_timeout 120 yt-dlp --flat-playlist --playlist-end 1 --print id "$url" 2>/dev/null) || rc=$?
            if (( rc != 0 )); then
                DISCOVERY_FAILURES=$((DISCOVERY_FAILURES + 1))
                note_issue "channel @$handle: feed fetch FAILED (rc=$rc); skipping this run"
                continue
            fi
            if [[ -z "$latest" ]]; then
                log "channel @$handle: empty feed"
                continue
            fi
            if grep -Fxq -- "$latest" "$STATE"; then
                # Already processed (channel was previously bootstrapped, then
                # cursor was lost). Adopt as cursor without ingesting.
                printf '%s\n' "$latest" > "$marker"
                log "channel @$handle: bootstrapped, cursor=$latest (already processed)"
            else
                # Queue, defer cursor write. If ingest lands, post-fan-out
                # writes cursor=$latest. If it fails, no cursor file exists
                # and the next run re-bootstraps (idempotent).
                printf '%s\n' "$latest" > "$discovered"
                log "channel @$handle: bootstrapping with $latest (cursor deferred)"
            fi
            continue
        fi

        cursor=$(<"$marker")
        cursor_trusted=true
        if ! grep -Fxq -- "$cursor" "$STATE"; then
            cursor_trusted=false
            log "channel @$handle: cursor $cursor not in .processed; treating as stale and walking past"
        fi

        pending_for_channel=()
        walked=0
        ended_early=false
        feed_rc_file="$(mktemp)"
        while IFS= read -r ID; do
            walked=$((walked + 1))
            (( walked > CHANNEL_WALK_LIMIT )) && { ended_early=true; break; }
            $cursor_trusted && [[ "$ID" == "$cursor" ]] && { ended_early=true; break; }
            grep -Fxq -- "$ID" "$STATE" && continue
            pending_for_channel+=("$ID")
        done < <(with_timeout 120 yt-dlp --flat-playlist --lazy-playlist --print id "$url" 2>/dev/null; printf '%s' "$?" >"$feed_rc_file")
        feed_rc="$(cat "$feed_rc_file" 2>/dev/null || printf '1')"
        rm -f "$feed_rc_file"

        # Only the EOF path may consult feed_rc: on EOF the subshell has
        # exited, so the rc file is complete. The early-break paths leave the
        # fetch mid-flight (its rc would be a SIGPIPE artefact anyway) — but
        # they ended the walk by design, so the feed was NOT truncated.
        feed_truncated=false
        if ! $ended_early && [[ "$feed_rc" != 0 ]]; then
            feed_truncated=true
        fi

        if (( ${#pending_for_channel[@]} > 0 )); then
            printf '%s\n' "${pending_for_channel[@]}" > "$discovered"
            if $feed_truncated; then
                # The feed died mid-stream: videos may exist between the old
                # cursor and the truncation point that this walk never saw.
                # Ingest what we found, but pin the cursor — advancing it past
                # unseen videos would skip them forever. The marker tells the
                # post-fan-out step to hold; next run re-walks from the same
                # cursor and rediscovers anything missed (dedup by .processed).
                : > "$discovered.partial"
                DISCOVERY_FAILURES=$((DISCOVERY_FAILURES + 1))
                note_issue "channel @$handle: pending=${#pending_for_channel[@]} but feed walk TRUNCATED mid-stream (rc=$feed_rc) — cursor pinned; full re-walk next run"
            else
                rm -f "$discovered.partial"
                log "channel @$handle: pending=${#pending_for_channel[@]} (cursor advance deferred to post-fan-out)"
            fi
        elif $feed_truncated; then
            # Nothing (usable) read and the fetch failed ⇒ "nothing new"
            # would be a lie.
            DISCOVERY_FAILURES=$((DISCOVERY_FAILURES + 1))
            note_issue "channel @$handle: feed fetch FAILED (rc=$feed_rc); skipping this run"
        else
            log "channel @$handle: nothing new"
        fi
    done
else
    # Distinguish "channel ingest was never enabled" (fine, stay quiet) from
    # "the config that was driving channel ingest is no longer where we look"
    # (a silent outage). The cursor files are the evidence: one exists per
    # channel we have actually ingested from, so their presence proves channels
    # WERE configured and working. Without this distinction a packaging or
    # path change orphans the config and every run still reports a cheerful,
    # successful no-op — which is precisely what happened for 15 days.
    shopt -s nullglob
    ORPHANED=()
    for f in "$CHANNELS_DIR"/*; do
        [[ "$f" == *.discovered || "$f" == *.partial ]] && continue
        ORPHANED+=("$(basename "$f")")
    done
    shopt -u nullglob
    if (( ${#ORPHANED[@]} > 0 )); then
        DISCOVERY_FAILURES=$((DISCOVERY_FAILURES + 1))
        note_issue "channels config MISSING at $CHANNELS_FILE, yet ${#ORPHANED[@]} channel(s) have ingest cursors (${ORPHANED[*]}) — the config was orphaned, not disabled. No channel ingest happened this run; set \$YOUTUBE_CHANNELS_FILE or restore ${CONFIG_DIR}/channels.yaml."
    else
        log "no channels file at $CHANNELS_FILE; skipping channel ingest (copy channels.example.yaml to enable)"
    fi
fi

# Build the fan-out order. Recovery orphans go first, so a recovered ID isn't
# shadowed by the same ID resurfacing from a feed. Then a round-robin across
# sources — the playlist and each channel — taking every source's newest
# pending video, then every source's second-newest, and so on. This fills the
# backlog newest-first ACROSS sources rather than draining one channel's whole
# history before touching the next, so the most recent content lands soonest
# (which matters now that pacing stretches a backlog over hours). Each source
# is already newest-first: the playlist via --playlist-reverse, channels via
# the newest-first feed walk captured in the .discovered files. Dedup keeps
# the first occurrence.
SOURCE_FILES=()
PLAYLIST_PENDING=""
if (( ${#PLAYLIST_NEW[@]} > 0 )); then
    PLAYLIST_PENDING="$(mktemp)"
    printf '%s\n' "${PLAYLIST_NEW[@]}" > "$PLAYLIST_PENDING"
    SOURCE_FILES+=("$PLAYLIST_PENDING")
fi
QUEUE_PENDING=""
if (( ${#QUEUE_NEW[@]} > 0 )); then
    QUEUE_PENDING="$(mktemp)"
    printf '%s\n' "${QUEUE_NEW[@]}" > "$QUEUE_PENDING"
    SOURCE_FILES+=("$QUEUE_PENDING")
fi
shopt -s nullglob
SOURCE_FILES+=("$CHANNELS_DIR"/*.discovered)
shopt -u nullglob

# Built via a temp file rather than `< <( ... )`: bash 3.2's parser cannot
# handle a MULTI-LINE process substitution and dies at runtime with
# "bad substitution: no closing `)' in <(". Single-line ones are fine.
QUEUE_FILE="$(mktemp)"
{
    {
        printf '%s\n' ${ORPHAN_NEW[@]+"${ORPHAN_NEW[@]}"}
        if (( ${#SOURCE_FILES[@]} > 0 )); then
            # Round-robin by recency rank: rows keyed (source, rank); emit
            # rank-major so slot N draws each source's Nth-newest in turn.
            awk '
                FNR == 1 { src++ }
                { rank[src]++; rows[src SUBSEP rank[src]] = $0
                  if (rank[src] > maxrank) maxrank = rank[src] }
                END {
                    for (r = 1; r <= maxrank; r++)
                        for (s = 1; s <= src; s++)
                            if ((s SUBSEP r) in rows) print rows[s SUBSEP r]
                }
            ' "${SOURCE_FILES[@]}"
        fi
    } | awk 'NF && !seen[$0]++'
} > "$QUEUE_FILE"

NEW=()
while IFS= read -r _line || [[ -n "$_line" ]]; do
    NEW+=("$_line")
done < "$QUEUE_FILE"
rm -f "$QUEUE_FILE"
if [[ -n "$PLAYLIST_PENDING" ]]; then rm -f "$PLAYLIST_PENDING"; fi
if [[ -n "$QUEUE_PENDING" ]]; then rm -f "$QUEUE_PENDING"; fi

# Defense-in-depth: a YouTube video ID is exactly 11 chars of [A-Za-z0-9_-].
# Anything else in the queue means a source fed us junk (the --help incident
# queued yt-dlp usage lines like "Options:" as IDs) — drop it loudly rather
# than fan out an ingest worker on it.
SANE=()
for ID in ${NEW[@]+"${NEW[@]}"}; do
    if [[ "$ID" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
        SANE+=("$ID")
    else
        log "dropping junk id from queue: $ID"
    fi
done
NEW=(${SANE[@]+"${SANE[@]}"})
fi

# Staleness backstop. Every other check in this script asks "did this step
# fail?"; none asks "is this pipeline still producing anything?". A config that
# quietly stops feeding the queue, a cursor set that never advances, an upstream
# that changes its feed shape — each reports success forever while the knowledge
# base silently freezes. Only a liveness check catches that class, so this is
# the one check that fires on the strength of a NON-event.
STAMP="$STATE_DIR/last-ingest"
[[ -f "$STAMP" ]] || date -u +%s > "$STAMP"   # seed: a fresh install must not alarm
check_staleness() {
    (( STALE_DAYS > 0 )) || return 0
    # Only meaningful when channels are tracked: a playlist-only setup
    # legitimately goes quiet forever once its playlist is drained.
    [[ -f "$CHANNELS_FILE" ]] || return 0
    local last age
    last="$(cat "$STAMP" 2>/dev/null || printf '0')"
    [[ "$last" =~ ^[0-9]+$ ]] || return 0
    age=$(( ( $(date -u +%s) - last ) / 86400 ))
    if (( age >= STALE_DAYS )); then
        note_issue "nothing ingested for ${age} days (threshold ${STALE_DAYS}) despite tracked channels — the pipeline is reporting success while producing nothing"
    fi
}

# The single exit path for every outcome past discovery: decide the verdict,
# alert on it, and set the exit code launchd records. Routing all outcomes
# through here is what guarantees an unhealthy run cannot exit quietly.
finish() {
    local summary="$1"
    if (( ${#ISSUES[@]} > 0 )); then
        notify problem "ytt ingest unhealthy (${#ISSUES[@]} issue(s)): $summary" "${ISSUES[@]}"
        exit 1
    fi
    notify ok "ytt ingest healthy: $summary" "$summary"
    exit 0
}

# Filter discovery to IDs that still need a YouTube fetch. Already-downloaded
# IDs skip download and wait for the analyze stage.
TO_DOWNLOAD=()
DOWNLOAD_REMAINING=0
if [[ "$STAGE" != analyze ]]; then
    for ID in ${NEW[@]+"${NEW[@]}"}; do
        if download_complete "$ID"; then
            continue
        fi
        if download_rejected "$ID"; then
            continue
        fi
        TO_DOWNLOAD+=("$ID")
    done
    DOWNLOAD_REMAINING=${#TO_DOWNLOAD[@]}
    if (( DOWNLOAD_BATCH > 0 && ${#TO_DOWNLOAD[@]} > DOWNLOAD_BATCH )); then
        log "download batch cap: taking $DOWNLOAD_BATCH of ${#TO_DOWNLOAD[@]} pending fetches"
        _sliced=()
        _n=0
        for ID in "${TO_DOWNLOAD[@]}"; do
            (( _n < DOWNLOAD_BATCH )) || break
            _sliced+=("$ID")
            _n=$((_n + 1))
        done
        TO_DOWNLOAD=(${_sliced[@]+"${_sliced[@]}"})
    fi
fi

collect_pending_analyze

if $DRY_RUN; then
    log "dry run: channels file = $CHANNELS_FILE"
    log "dry run: ${#TO_DOWNLOAD[@]} video(s) would be downloaded, ${#PENDING_ANALYZE[@]} pending analysis"
    check_staleness
    if (( ${#TO_DOWNLOAD[@]} > 0 )); then
        printf '# download\n'
        printf '%s\n' "${TO_DOWNLOAD[@]}"
    fi
    if (( ${#PENDING_ANALYZE[@]} > 0 )); then
        printf '# analyze\n'
        printf '%s\n' "${PENDING_ANALYZE[@]}"
    fi
    finish "dry run, ${#TO_DOWNLOAD[@]} to download, ${#PENDING_ANALYZE[@]} to analyze"
fi

if (( ${#TO_DOWNLOAD[@]} == 0 )) && { [[ "$STAGE" == download ]] || (( ${#PENDING_ANALYZE[@]} == 0 )); }; then
    check_staleness
    if (( DISCOVERY_FAILURES > 0 )); then
        log "nothing to do — but $DISCOVERY_FAILURES discovery source(s) FAILED; results incomplete"
    else
        log "nothing to do"
    fi
    finish "nothing to do"
fi

DOWNLOADED=0
DOWNLOAD_FAILED=0
download_rc=0
if [[ "$STAGE" != analyze ]] && (( ${#TO_DOWNLOAD[@]} > 0 )); then
    log "downloading ${#TO_DOWNLOAD[@]} videos"
    printf '%s\n' "${TO_DOWNLOAD[@]}" \
        | with_timeout "$RUN_TIMEOUT" xargs -n 1 -P "$CONCURRENCY" "$HERE/ingest-one.sh" --download \
        || download_rc=$?
    if (( download_rc == 124 )); then
        log "run watchdog: download fan-out exceeded ${RUN_TIMEOUT}s — terminated; unfinished fetches retry next tick"
        note_issue "download watchdog fired: the fan-out exceeded ${RUN_TIMEOUT}s and was terminated"
    fi
    PERM_FAIL=0
    for ID in ${TO_DOWNLOAD[@]+"${TO_DOWNLOAD[@]}"}; do
        if download_complete "$ID"; then
            DOWNLOADED=$((DOWNLOADED + 1))
        elif download_rejected "$ID"; then
            PERM_FAIL=$((PERM_FAIL + 1))
        else
            DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
        fi
    done
    log "downloaded $DOWNLOADED, $PERM_FAIL undownloadable, $DOWNLOAD_FAILED failed this tick"
    if (( PERM_FAIL > 0 )); then
        log "recorded $PERM_FAIL undownloadable id(s); skipped on later ticks"
    fi
    if (( DOWNLOAD_FAILED > 0 )) && (( download_rc != 124 )); then
        note_issue "$DOWNLOAD_FAILED of ${#TO_DOWNLOAD[@]} download(s) failed this tick and stay pending"
    fi
    # ingest-one exits 1 for undownloadable ids so xargs records a failure;
    # that is expected and already counted in PERM_FAIL. Do not let BSD
    # xargs's non-zero status become a phantom "fan-out exited non-zero".
    if (( DOWNLOAD_FAILED == 0 )) && (( download_rc != 124 )); then
        download_rc=0
    fi
fi

# Analyze everything now on disk, including this tick's downloads.
# Not YouTube-throttled. Capacity 255 stops the analyze fan-out only.
INGESTED=0
analyze_rc=0
SPEND_LIMITED=false
if [[ "$STAGE" != download ]]; then
    collect_pending_analyze
    if (( ${#PENDING_ANALYZE[@]} > 0 )); then
        log "analyzing ${#PENDING_ANALYZE[@]} videos"
        rm -f "$ROOT/.spend-limit"
        printf '%s\n' "${PENDING_ANALYZE[@]}" \
            | with_timeout "$RUN_TIMEOUT" xargs -n 1 -P "$ANALYZE_CONCURRENCY" "$HERE/ingest-one.sh" --analyze \
            || analyze_rc=$?
        if [[ -f "$ROOT/.spend-limit" ]]; then
            SPEND_LIMITED=true
            rm -f "$ROOT/.spend-limit"
        fi
        if (( analyze_rc == 124 )) && ! $SPEND_LIMITED; then
            log "run watchdog: analyze fan-out exceeded ${RUN_TIMEOUT}s — terminated; unfinished synopses retry next tick"
            note_issue "analyze watchdog fired: the fan-out exceeded ${RUN_TIMEOUT}s and was terminated"
        fi
        for ID in ${PENDING_ANALYZE[@]+"${PENDING_ANALYZE[@]}"}; do
            grep -Fxq -- "$ID" "$STATE" && INGESTED=$((INGESTED + 1))
        done
        ANALYZE_LEFT=$(( ${#PENDING_ANALYZE[@]} - INGESTED ))
        if $SPEND_LIMITED; then
            log "analyzed $INGESTED, $ANALYZE_LEFT deferred (synopsis providers at capacity)"
            note_issue "synopsis providers at capacity — $ANALYZE_LEFT video(s) stay on disk for the next analyze tick"
        elif (( ANALYZE_LEFT > 0 )) && (( analyze_rc != 124 )); then
            log "analyzed $INGESTED, $ANALYZE_LEFT failed"
            note_issue "$ANALYZE_LEFT of ${#PENDING_ANALYZE[@]} analyze(s) failed this tick and stay on disk"
        else
            log "analyzed $INGESTED"
        fi
    fi
fi

FAILED=$DOWNLOAD_FAILED
run_rc=0
if (( download_rc != 0 )); then run_rc=$download_rc; fi
if (( analyze_rc != 0 )); then run_rc=$analyze_rc; fi

# Deferred channel-cursor advance. For each channel that had discoveries,
# walk the discovery list oldest-first; cursor advances over each
# contiguous landed ID and stops at the first non-landed. This guarantees
# every ID above the new cursor is either already in .processed or still
# pending, so failed ingests get retried next run.
shopt -s nullglob
for discovered in "$CHANNELS_DIR"/*.discovered; do
    handle="$(basename "$discovered" .discovered)"
    marker="$CHANNELS_DIR/$handle"
    if [[ -f "$discovered.partial" ]]; then
        log "channel @$handle: cursor unchanged (feed walk truncated; full re-walk next run)"
        rm -f "$discovered" "$discovered.partial"
        continue
    fi
    ids=()
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        ids+=("$_line")
    done < "$discovered"
    new_cursor=""
    for ((i = ${#ids[@]} - 1; i >= 0; i--)); do
        if grep -Fxq -- "${ids[$i]}" "$STATE"; then
            new_cursor="${ids[$i]}"
        else
            break
        fi
    done
    if [[ -n "$new_cursor" ]]; then
        printf '%s\n' "$new_cursor" > "$marker"
        log "channel @$handle: cursor → $new_cursor"
    else
        log "channel @$handle: cursor unchanged (no discovered ingests landed)"
    fi
    rm -f "$discovered"
done
shopt -u nullglob

if (( DISCOVERY_FAILURES > 0 )); then
    log "warning: $DISCOVERY_FAILURES discovery source(s) FAILED this run; anything they held surfaces next run"
fi
log "done: downloaded=$DOWNLOADED analyzed=$INGESTED download_failed=$DOWNLOAD_FAILED"

# Liveness stamp: only a landed video counts. Advancing this on a merely
# error-free run would defeat the staleness check entirely.
if (( INGESTED > 0 )); then
    date -u +%s > "$STAMP"
elif [[ "$STAGE" != download ]]; then
    # Download ticks produce no .processed rows; staleness is an analyze
    # concern (knowledge landing), not a fetch concern.
    check_staleness
fi

# Refresh the knowledge-base index whenever new synopses landed. Without
# this the per-video files exist but the user-facing summary page stays
# frozen — exactly the symptom that prompted this design pass.
if (( INGESTED > 0 )); then
    if "$YTT_BIN" build-index >>"$LOG" 2>&1; then
        log "index refreshed"
    else
        log "index refresh failed (see $LOG)"
        note_issue "knowledge-base index refresh FAILED — $INGESTED new synopsis file(s) exist but the index page is stale"
    fi
fi

# launchd has no knowledge of the per-worker log. A partial batch is not a
# healthy run: return failure so its last-exit-code, and any future scheduler,
# reflect the pending retry rather than falsely reporting success. The
# run_rc term below is belt-and-braces: every other failure condition has
# already called note_issue, so finish() fails the run on $ISSUES alone.
if (( run_rc != 0 )) && (( ${#ISSUES[@]} == 0 )); then
    note_issue "fan-out exited non-zero (rc=$run_rc) with no per-video failure recorded"
fi
finish "downloaded $DOWNLOADED, analyzed $INGESTED"
