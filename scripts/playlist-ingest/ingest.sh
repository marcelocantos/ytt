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
# seen so far. On first sight (no cursor): the channel's latest video is
# ingested and recorded as the cursor — no backfill of older uploads.
# On subsequent runs: the channel's upload feed is walked newest-first and
# every video newer than the cursor is ingested. Cursor is then advanced.
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
HERE="$(cd "$(dirname "$0")" && pwd)"
CHANNELS_FILE="${YOUTUBE_CHANNELS_FILE:-$HERE/channels.yaml}"

export YOUTUBE_INGEST_ROOT="$ROOT"

mkdir -p "$ROOT" "$CHANNELS_DIR"
touch "$STATE" "$LOG"

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2
}

log "playlist=$PLAYLIST root=$ROOT concurrency=$CONCURRENCY"

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
#   Bootstrap (no cursor): take the latest upload, record it as the cursor,
#   queue it for ingest unless already in .processed.
#   Steady state: walk the upload feed newest-first, stopping at the cursor.
#   Everything above the cursor (and not already in .processed) is queued.
CHANNEL_NEW=()
if [[ -f "$CHANNELS_FILE" ]]; then
    mapfile -t HANDLES < <(yq -r '.channels[].handle' "$CHANNELS_FILE")
    for handle in "${HANDLES[@]}"; do
        handle="${handle#@}"
        [[ -n "$handle" ]] || continue
        url="https://www.youtube.com/@${handle}/videos"
        marker="$CHANNELS_DIR/$handle"

        if [[ ! -f "$marker" ]]; then
            latest=$(yt-dlp --flat-playlist --playlist-end 1 --print id "$url" 2>/dev/null)
            if [[ -z "$latest" ]]; then
                log "channel @$handle: empty feed"
                continue
            fi
            printf '%s\n' "$latest" > "$marker"
            if grep -Fxq -- "$latest" "$STATE"; then
                log "channel @$handle: bootstrapped, cursor=$latest (already processed)"
            else
                log "channel @$handle: bootstrapping with $latest"
                CHANNEL_NEW+=("$latest")
            fi
            continue
        fi

        cursor=$(<"$marker")
        # Lazy walk: stream IDs from yt-dlp, break as soon as cursor is hit.
        pending_for_channel=()
        while IFS= read -r ID; do
            [[ "$ID" == "$cursor" ]] && break
            grep -Fxq -- "$ID" "$STATE" && continue
            pending_for_channel+=("$ID")
        done < <(yt-dlp --flat-playlist --lazy-playlist --print id "$url" 2>/dev/null)

        if (( ${#pending_for_channel[@]} > 0 )); then
            # Advance cursor to the newest collected ID.
            printf '%s\n' "${pending_for_channel[0]}" > "$marker"
            CHANNEL_NEW+=("${pending_for_channel[@]}")
            log "channel @$handle: pending=${#pending_for_channel[@]} new cursor=${pending_for_channel[0]}"
        else
            log "channel @$handle: nothing new"
        fi
    done
else
    log "no channels file at $CHANNELS_FILE; skipping channel ingest (copy channels.example.yaml to enable)"
fi

# Merge + dedup (a video could appear in both the playlist and a channel).
mapfile -t NEW < <(
    { printf '%s\n' "${PLAYLIST_NEW[@]}"; printf '%s\n' "${CHANNEL_NEW[@]}"; } \
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

log "done: $INGESTED ingested, $FAILED failed"
