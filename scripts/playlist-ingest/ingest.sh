#!/usr/bin/env bash
# Ingest new videos from a YouTube playlist and from tracked channels.
#
# Usage: ingest.sh [PLAYLIST_URL]
#   PLAYLIST_URL defaults to $YOUTUBE_INGEST_PLAYLIST.
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

set -euo pipefail

PLAYLIST="${1:-${YOUTUBE_INGEST_PLAYLIST:-}}"
if [[ -z "$PLAYLIST" ]]; then
    echo "error: playlist URL required (arg or \$YOUTUBE_INGEST_PLAYLIST)" >&2
    exit 2
fi

ROOT="${YOUTUBE_INGEST_ROOT:-$HOME/think/knowledge/youtube}"
STATE="$ROOT/.processed"
LOG="$ROOT/.ingest.log"
CHANNELS_DIR="$ROOT/.channels"
CONCURRENCY="${YOUTUBE_INGEST_CONCURRENCY:-4}"
# Safety limit on how deep into a channel feed we'll walk in one run.
# Bounds the worst case when a cursor is stale or missing.
CHANNEL_WALK_LIMIT=50
HERE="$(cd "$(dirname "$0")" && pwd)"
CHANNELS_FILE="${YOUTUBE_CHANNELS_FILE:-$HERE/channels.yaml}"

export YOUTUBE_INGEST_ROOT="$ROOT"

mkdir -p "$ROOT" "$CHANNELS_DIR"
touch "$STATE" "$LOG"

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2
}

log "playlist=$PLAYLIST root=$ROOT concurrency=$CONCURRENCY"

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
mapfile -t PLAYLIST_IDS < <(
    yt-dlp --flat-playlist --print id --playlist-reverse "$PLAYLIST"
)

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
#   $CHANNELS_DIR/<handle>.discovered for the post-fan-out cursor advance.
CHANNEL_NEW=()
if [[ -f "$CHANNELS_FILE" ]]; then
    mapfile -t HANDLES < <(yq -r '.channels[].handle' "$CHANNELS_FILE")
    for handle in "${HANDLES[@]}"; do
        handle="${handle#@}"
        [[ -n "$handle" ]] || continue
        url="https://www.youtube.com/@${handle}/videos"
        marker="$CHANNELS_DIR/$handle"
        discovered="$CHANNELS_DIR/$handle.discovered"

        if [[ ! -f "$marker" ]]; then
            latest=$(yt-dlp --flat-playlist --playlist-end 1 --print id "$url" 2>/dev/null)
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
                CHANNEL_NEW+=("$latest")
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
        while IFS= read -r ID; do
            walked=$((walked + 1))
            (( walked > CHANNEL_WALK_LIMIT )) && break
            $cursor_trusted && [[ "$ID" == "$cursor" ]] && break
            grep -Fxq -- "$ID" "$STATE" && continue
            pending_for_channel+=("$ID")
        done < <(yt-dlp --flat-playlist --lazy-playlist --print id "$url" 2>/dev/null)

        if (( ${#pending_for_channel[@]} > 0 )); then
            printf '%s\n' "${pending_for_channel[@]}" > "$discovered"
            CHANNEL_NEW+=("${pending_for_channel[@]}")
            log "channel @$handle: pending=${#pending_for_channel[@]} (cursor advance deferred to post-fan-out)"
        else
            log "channel @$handle: nothing new"
        fi
    done
else
    log "no channels file at $CHANNELS_FILE; skipping channel ingest (copy channels.example.yaml to enable)"
fi

# Merge + dedup. Orphans go first so a recovered ID isn't shadowed by the
# same ID surfacing again from a playlist or channel walk.
mapfile -t NEW < <(
    { printf '%s\n' "${ORPHAN_NEW[@]}"
      printf '%s\n' "${PLAYLIST_NEW[@]}"
      printf '%s\n' "${CHANNEL_NEW[@]}"; } \
        | awk 'NF && !seen[$0]++'
)

if (( ${#NEW[@]} == 0 )); then
    log "nothing to do"
    exit 0
fi

log "ingesting ${#NEW[@]} videos"

# Fan out. xargs -P bounds concurrency; each worker is one ingest-one.sh
# invocation. Workers exit non-zero on failure but xargs continues on the
# rest; the failures stay out of .processed so they retry next run.
printf '%s\n' "${NEW[@]}" \
    | xargs -n 1 -P "$CONCURRENCY" "$HERE/ingest-one.sh" \
    || true

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

log "done: $INGESTED ingested, $FAILED failed"

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
