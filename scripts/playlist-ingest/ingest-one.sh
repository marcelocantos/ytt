#!/usr/bin/env bash
# Ingest a single YouTube video by ID into the knowledge base.
# Intended to be invoked in parallel by ingest.sh; safe to run standalone.
#
# Usage: ingest-one.sh [--download|--analyze] <video-id>
#   --download  paced transcript + metadata fetch only (no synopsis)
#   --analyze   synopsis an already-downloaded video (no YouTube fetch)
#   neither     download (if needed) then analyze
#
# Honours $YOUTUBE_INGEST_ROOT (default ~/think/knowledge/youtube).
# Appends "<id>" to $ROOT/.processed on successful analysis.
# Logs to $ROOT/.ingest.log.
#
# Rate limiting applies to --download only (shared across parallel
# workers — keeps YouTube from IP-blocking this egress IP). Consecutive
# YouTube requests are spaced by a random delay:
#   $YOUTUBE_INGEST_FETCH_INTERVAL_MIN  min seconds between requests (default 180)
#   $YOUTUBE_INGEST_FETCH_INTERVAL_MAX  max seconds between requests (default 420)
#   $YOUTUBE_INGEST_FETCH_RETRIES       transcript attempts on IP-block (default 3)
#
# Analysis is not YouTube-throttled. A synopsis/capacity failure leaves
# the download on disk for the next analyze tick.

set -euo pipefail

MODE=all
while [[ $# -gt 0 ]]; do
    case "$1" in
        --download) MODE=download; shift ;;
        --analyze)  MODE=analyze;  shift ;;
        --) shift; break ;;
        # YouTube IDs are 11 chars of [A-Za-z0-9_-] and often start with
        # '-'. Treat a well-formed ID as the operand, not an unknown flag.
        # (2026-08-22: `-Gj0-EIyx6g` made every download tick UNHEALTHY.)
        -*)
            if [[ "$1" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
                break
            fi
            printf 'ingest-one: unknown flag: %s\n' "$1" >&2
            exit 2
            ;;
        *) break ;;
    esac
done

ID="${1:?video id required}"
# Validate at the point of danger: $ID lands in `rm -rf "$ROOT/$ID"` on
# download-failure paths, so a malformed argument must die here, not there.
# Real YouTube IDs are exactly 11 chars of [A-Za-z0-9_-].
if [[ ! "$ID" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    printf 'ingest-one: invalid video id: %s\n' "$ID" >&2
    exit 2
fi
ROOT="${YOUTUBE_INGEST_ROOT:-$HOME/think/knowledge/youtube}"
STATE="$ROOT/.processed"
FAILED_IDS="$ROOT/.download-failed"
LOG="${YOUTUBE_INGEST_LOG:-$ROOT/.ingest.log}"
DIR="$ROOT/$ID"
URL="https://www.youtube.com/watch?v=$ID"
YTT_BIN="${YOUTUBE_INGEST_YTT_BIN:-ytt}"

log() {
    printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$ID" "$*" >>"$LOG"
}

mkdir -p "$ROOT"
if ! YTT_BIN="$(command -v "$YTT_BIN")"; then
    log "ytt executable not found: ${YOUTUBE_INGEST_YTT_BIN:-ytt}; aborting"
    exit 1
fi

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
with_timeout() {
    local secs="$1"; shift
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" --kill-after=10 "$secs" "$@"
    else
        "$@"
    fi
}

download_complete() {
    [[ -s "$DIR/.transcript/transcript.json" && -s "$DIR/meta.json" ]]
}

synopsis_file() {
    find "$DIR" -maxdepth 1 -type f -name '*.md' ! -name 'transcript*' -print -quit
}

# --- Cross-worker YouTube request pacing (download only) -----------------
FETCH_MIN="${YOUTUBE_INGEST_FETCH_INTERVAL_MIN:-180}"
FETCH_MAX="${YOUTUBE_INGEST_FETCH_INTERVAL_MAX:-420}"
GATE="$ROOT/.fetch.lock"
STAMP="$ROOT/.fetch.stamp"

throttle() {
    while ! mkdir "$GATE" 2>/dev/null; do
        if find "$GATE" -maxdepth 0 -mmin +1 2>/dev/null | grep -q .; then
            rm -rf "$GATE"
            continue
        fi
        sleep 0.5
    done
    local now interval last target
    now=$(date +%s)
    interval=$(( FETCH_MIN + RANDOM % (FETCH_MAX - FETCH_MIN + 1) ))
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    target=$(( last + interval ))
    if (( target < now )); then
        target=$now
    fi
    printf '%s\n' "$target" >"$STAMP"
    rm -rf "$GATE"
    local sleep_for=$(( target - now ))
    if (( sleep_for > 0 )); then
        log "pacing: holding ${sleep_for}s for next YouTube request slot"
        sleep "$sleep_for"
    fi
}

record_download_failed() {
    # One ID per line. Short writes are atomic on POSIX; concurrent workers
    # can append without a lock the same way they append .processed.
    printf '%s\n' "$ID" >>"$FAILED_IDS"
}

do_download() {
    if download_complete; then
        log "already downloaded"
        return 0
    fi
    if grep -Fxq -- "$ID" "$FAILED_IDS" 2>/dev/null; then
        log "already recorded undownloadable; skipping"
        return 0
    fi

    mkdir -p "$DIR/.transcript"
    log "download start"
    set -o pipefail

    RAW="$DIR/.transcript/transcript.raw.json"
    attempt=0
    max_attempts="${YOUTUBE_INGEST_FETCH_RETRIES:-3}"
    while :; do
        mkdir -p "$DIR/.transcript"
        throttle
        rc=0
        err=$(with_timeout 120 "$YTT_BIN" --json "$URL" 2>&1 >"$RAW") || rc=$?
        if (( rc == 0 )); then
            break
        fi
        printf '%s\n' "$err" >>"$LOG"
        attempt=$((attempt + 1))
        if { (( rc != 124 )) && ! grep -qiE 'blocked|too ?many ?requests|429' <<<"$err"; } \
            || (( attempt >= max_attempts )); then
            log "ytt failed (rc=$rc); recording as undownloadable"
            record_download_failed
            rm -rf "$DIR"
            exit 1
        fi
        log "transcript fetch failed (rc=$rc); will retry ($attempt/$max_attempts) after the next pacing slot"
    done

    if ! jq . "$RAW" >"$DIR/.transcript/transcript.json"; then
        log "transcript json malformed; recording as undownloadable"
        record_download_failed
        rm -rf "$DIR"
        exit 1
    fi
    rm -f "$RAW"

    if ! with_timeout 120 yt-dlp --skip-download --print-json "$URL" 2>>"$LOG" \
        | jq '{id, title, uploader, channel, channel_id, upload_date,
               duration, view_count, description, webpage_url, tags}' \
        >"$DIR/meta.json"; then
        log "meta fetch failed; recording as undownloadable"
        record_download_failed
        rm -rf "$DIR"
        exit 1
    fi

    TITLE=$(jq -r '.title // "(unknown)"' "$DIR/meta.json" 2>/dev/null || echo "(unknown)")
    log "downloaded ($TITLE)"
}

do_analyze() {
    if grep -Fxq -- "$ID" "$STATE" 2>/dev/null; then
        log "already analyzed"
        return 0
    fi
    if ! download_complete; then
        log "analyze skipped: download incomplete"
        exit 1
    fi

    existing="$(synopsis_file)"
    if [[ -n "$existing" && -s "$existing" ]]; then
        printf '%s\n' "$ID" >>"$STATE"
        log "analyzed (existing synopsis $(basename "$existing"))"
        return 0
    fi

    TITLE=$(jq -r '.title // "(unknown)"' "$DIR/meta.json" 2>/dev/null || echo "(unknown)")
    log "analyze start"

    SYNOPSIS_OUT="$DIR/.transcript/synopsis.out"
    rc=0
    with_timeout 1800 "$YTT_BIN" synopsis \
        --dir "$DIR" --title "$TITLE" --url "$URL" >"$SYNOPSIS_OUT" 2>&1 || rc=$?
    if (( rc != 0 )); then
        cat "$SYNOPSIS_OUT" >>"$LOG" 2>/dev/null || true
        rm -f "$SYNOPSIS_OUT"
        if (( rc == 255 )); then
            : > "$ROOT/.spend-limit"
            log "synopsis ladder exhausted on capacity; aborting analyze so the rest defers (exit 255 stops xargs)"
            exit 255
        fi
        log "synopsis failed; download kept for retry"
        exit 1
    fi
    cat "$SYNOPSIS_OUT" >>"$LOG"
    rm -f "$SYNOPSIS_OUT"

    SYNOPSIS="$(synopsis_file)"
    if [[ -z "$SYNOPSIS" || ! -s "$SYNOPSIS" ]]; then
        log "synopsis file missing or empty; download kept for retry"
        exit 1
    fi

    printf '%s\n' "$ID" >>"$STATE"
    log "analyzed ($TITLE)"
}

case "$MODE" in
    download) do_download ;;
    analyze)  do_analyze ;;
    all)
        do_download
        do_analyze
        ;;
esac
