#!/usr/bin/env bash
# Ingest new videos from a YouTube playlist and from tracked channels.
#
# Usage: ingest.sh [PLAYLIST_URL]
#   PLAYLIST_URL defaults to $YOUTUBE_INGEST_PLAYLIST and must be an
#   http(s) URL. -h/--help prints this header.
#
# Sources:
#   1. The playlist named by PLAYLIST_URL / $YOUTUBE_INGEST_PLAYLIST.
#   2. The channels listed in $YOUTUBE_CHANNELS_FILE
#      (default: ../channel-ingest/channels.yaml).
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
# Output:      $YOUTUBE_INGEST_ROOT     (default ~/think/knowledge/youtube)
# Network:     the run waits for connectivity before discovery — the daily
#              launchd tick usually fires in a DarkWake maintenance window
#              with no Wi-Fi, where every DNS lookup fails.
#              $YOUTUBE_INGEST_NETWORK_WAIT caps the wait (default 14400s);
#              $YOUTUBE_INGEST_NETWORK_POLL sets the poll interval (default 60s).

set -euo pipefail

case "${1:-}" in
    -h|--help)
        # The header comment doubles as the usage text.
        awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "$0"
        exit 0
        ;;
esac

PLAYLIST="${1:-${YOUTUBE_INGEST_PLAYLIST:-}}"
if [[ -z "$PLAYLIST" ]]; then
    echo "error: playlist URL required (arg or \$YOUTUBE_INGEST_PLAYLIST)" >&2
    exit 2
fi
# Anything that isn't an http(s) URL — a stray flag, a bare word — must never
# reach yt-dlp as the playlist: `ingest.sh --help` once became
# playlist="--help", yt-dlp printed its own help text, and 851 lines of usage
# output were queued as "video IDs" for ingest.
if [[ "$PLAYLIST" != http://* && "$PLAYLIST" != https://* ]]; then
    echo "error: playlist must be an http(s) URL, got: $PLAYLIST" >&2
    exit 2
fi

ROOT="${YOUTUBE_INGEST_ROOT:-$HOME/think/knowledge/youtube}"
STATE="$ROOT/.processed"
# Log defaults into the content tree for manual use; the scheduled runner
# points $YOUTUBE_INGEST_LOG outside it so scheduled churn doesn't commit.
LOG="${YOUTUBE_INGEST_LOG:-$ROOT/.ingest.log}"
CHANNELS_DIR="$ROOT/.channels"
CONCURRENCY="${YOUTUBE_INGEST_CONCURRENCY:-4}"
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
CHANNELS_FILE="${YOUTUBE_CHANNELS_FILE:-$HERE/channels.yaml}"

export YOUTUBE_INGEST_ROOT="$ROOT"

mkdir -p "$ROOT" "$CHANNELS_DIR"
touch "$STATE" "$LOG"

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG" >&2
}

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
    log "curl not found on PATH — cannot probe network reachability; aborting"
    exit 1
fi
network_up() {
    curl -fsI --max-time 10 -o /dev/null https://www.youtube.com/robots.txt
}
WAITED=0
until network_up; do
    if (( WAITED >= NETWORK_WAIT )); then
        log "network still unreachable after ${WAITED}s of waiting; giving up (next scheduled run retries)"
        exit 1
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

# Heal orphan dirs from previous failed runs. The .processed file is the
# authoritative record of successful ingest; any per-video dir that exists
# without being in .processed was killed mid-run, had its synopsis step
# fail, or otherwise crashed before ingest-one.sh could record success.
# Wipe the half-built dir and queue the ID for a fresh attempt below.
shopt -s nullglob
ORPHAN_NEW=()
for dir in "$ROOT"/*/; do
    id="$(basename "$dir")"
    grep -Fxq -- "$id" "$STATE" && continue
    ORPHAN_NEW+=("$id")
    rm -rf "$dir"
done
shopt -u nullglob

if (( ${#ORPHAN_NEW[@]} > 0 )); then
    log "orphan dirs from failed prior runs (queued for retry): ${ORPHAN_NEW[*]}"
fi

# Collect new IDs from the playlist.
PLAYLIST_IDS=()
PLAYLIST_LIST="$(mktemp)"
if with_timeout 120 yt-dlp --flat-playlist --print id --playlist-reverse "$PLAYLIST" >"$PLAYLIST_LIST"; then
    mapfile -t PLAYLIST_IDS <"$PLAYLIST_LIST"
else
    rc=$?
    DISCOVERY_FAILURES=$((DISCOVERY_FAILURES + 1))
    log "playlist enumeration FAILED (rc=$rc); playlist skipped this run"
fi
rm -f "$PLAYLIST_LIST"

PLAYLIST_NEW=()
for ID in "${PLAYLIST_IDS[@]}"; do
    grep -Fxq -- "$ID" "$STATE" || PLAYLIST_NEW+=("$ID")
done
log "playlist=${#PLAYLIST_IDS[@]} pending=${#PLAYLIST_NEW[@]}"

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
    mapfile -t HANDLES < <(yq -r '.channels[].handle' "$CHANNELS_FILE")
    for handle in "${HANDLES[@]}"; do
        handle="${handle#@}"
        [[ -n "$handle" ]] || continue
        url="https://www.youtube.com/@${handle}/videos"
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
                log "channel @$handle: feed fetch FAILED (rc=$rc); skipping this run"
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
                log "channel @$handle: pending=${#pending_for_channel[@]} but feed walk TRUNCATED mid-stream (rc=$feed_rc) — cursor pinned; full re-walk next run"
            else
                rm -f "$discovered.partial"
                log "channel @$handle: pending=${#pending_for_channel[@]} (cursor advance deferred to post-fan-out)"
            fi
        elif $feed_truncated; then
            # Nothing (usable) read and the fetch failed ⇒ "nothing new"
            # would be a lie.
            DISCOVERY_FAILURES=$((DISCOVERY_FAILURES + 1))
            log "channel @$handle: feed fetch FAILED (rc=$feed_rc); skipping this run"
        else
            log "channel @$handle: nothing new"
        fi
    done
else
    log "no channels file at $CHANNELS_FILE; skipping channel ingest (copy channels.example.yaml to enable)"
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
shopt -s nullglob
SOURCE_FILES+=("$CHANNELS_DIR"/*.discovered)
shopt -u nullglob

mapfile -t NEW < <(
    {
        printf '%s\n' "${ORPHAN_NEW[@]}"
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
)
if [[ -n "$PLAYLIST_PENDING" ]]; then rm -f "$PLAYLIST_PENDING"; fi

# Defense-in-depth: a YouTube video ID is exactly 11 chars of [A-Za-z0-9_-].
# Anything else in the queue means a source fed us junk (the --help incident
# queued yt-dlp usage lines like "Options:" as IDs) — drop it loudly rather
# than fan out an ingest worker on it.
SANE=()
for ID in "${NEW[@]}"; do
    if [[ "$ID" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
        SANE+=("$ID")
    else
        log "dropping junk id from queue: $ID"
    fi
done
NEW=("${SANE[@]}")

if (( ${#NEW[@]} == 0 )); then
    if (( DISCOVERY_FAILURES > 0 )); then
        log "nothing to do — but $DISCOVERY_FAILURES discovery source(s) FAILED; results incomplete"
        exit 1
    fi
    log "nothing to do"
    exit 0
fi

log "ingesting ${#NEW[@]} videos"

# Fan out. xargs -P bounds concurrency; each worker is one ingest-one.sh
# invocation. Per-video failures exit non-zero and xargs carries on; those IDs
# stay out of .processed and retry next run. The exception is a Claude
# spend-limit refusal: that worker drops a .spend-limit marker and exits 255,
# which makes xargs stop reading input — dispatching no more videos. (xargs's
# own exit status for the 255-abort differs across BSD and GNU, so the marker
# file — not the exit code — is what we trust here.)
rm -f "$ROOT/.spend-limit"
run_rc=0
printf '%s\n' "${NEW[@]}" \
    | with_timeout "$RUN_TIMEOUT" xargs -n 1 -P "$CONCURRENCY" "$HERE/ingest-one.sh" \
    || run_rc=$?
SPEND_LIMITED=false
if [[ -f "$ROOT/.spend-limit" ]]; then
    SPEND_LIMITED=true
    rm -f "$ROOT/.spend-limit"
fi
# run_rc 124 ⇒ the with_timeout cap fired (the run watchdog). Gate the report
# on the spend-limit marker: GNU xargs ALSO exits 124 when a worker exits 255
# (the spend-limit abort) while BSD xargs exits 1, so 124 alone is ambiguous —
# the marker is the reliable spend-limit signal. Workers killed by the cap are
# bounded by the per-call timeouts and exit on their own within minutes.
if (( run_rc == 124 )) && ! $SPEND_LIMITED; then
    log "run watchdog: fan-out exceeded ${RUN_TIMEOUT}s — terminated; unfinished videos retry next run"
fi

# Recount from state file (authoritative).
INGESTED=0
for ID in "${NEW[@]}"; do
    grep -Fxq -- "$ID" "$STATE" && INGESTED=$((INGESTED + 1))
done
FAILED=$(( ${#NEW[@]} - INGESTED ))

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
    mapfile -t ids < "$discovered"
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

if $SPEND_LIMITED; then
    log "done: $INGESTED ingested, $FAILED deferred (Claude spend limit hit — run cut short; remainder retries next run)"
else
    log "done: $INGESTED ingested, $FAILED failed"
fi
if (( DISCOVERY_FAILURES > 0 )); then
    log "warning: $DISCOVERY_FAILURES discovery source(s) FAILED this run; anything they held surfaces next run"
fi

# Refresh the knowledge-base index whenever new synopses landed. Without
# this the per-video files exist but the user-facing summary page stays
# frozen — exactly the symptom that prompted this design pass.
if (( INGESTED > 0 )); then
    if "$HERE/build-index.sh" >>"$LOG" 2>&1; then
        log "index refreshed"
    else
        log "index refresh failed (see $LOG)"
    fi
fi
