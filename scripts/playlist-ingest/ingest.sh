#!/usr/bin/env bash
# Ingest new videos from a YouTube playlist into the local knowledge base.
#
# Usage: ingest.sh [PLAYLIST_URL]
#   PLAYLIST_URL defaults to $YOUTUBE_INGEST_PLAYLIST.
#
# Enumerates the playlist, diffs against $ROOT/.processed, and fans out
# the new videos to ingest-one.sh in parallel.
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
CONCURRENCY="${YOUTUBE_INGEST_CONCURRENCY:-4}"
HERE="$(cd "$(dirname "$0")" && pwd)"

export YOUTUBE_INGEST_ROOT="$ROOT"

mkdir -p "$ROOT"
touch "$STATE" "$LOG"

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2
}

log "playlist=$PLAYLIST root=$ROOT concurrency=$CONCURRENCY"

mapfile -t IDS < <(
    yt-dlp --flat-playlist --print id --playlist-reverse "$PLAYLIST"
)

if (( ${#IDS[@]} == 0 )); then
    log "no videos found in playlist; aborting"
    exit 0
fi

# Filter to unprocessed IDs.
NEW=()
for ID in "${IDS[@]}"; do
    grep -Fxq "$ID" "$STATE" || NEW+=("$ID")
done

log "playlist=${#IDS[@]} processed=$(( ${#IDS[@]} - ${#NEW[@]} )) pending=${#NEW[@]}"

if (( ${#NEW[@]} == 0 )); then
    log "nothing to do"
    exit 0
fi

# Fan out. xargs -P bounds concurrency; each worker is one ingest-one.sh
# invocation. Workers exit non-zero on failure but xargs continues on the
# rest; the failures stay out of .processed so they retry next run.
printf '%s\n' "${NEW[@]}" \
    | xargs -n 1 -P "$CONCURRENCY" "$HERE/ingest-one.sh" \
    || true

# Recount from state file (authoritative).
INGESTED=0
for ID in "${NEW[@]}"; do
    grep -Fxq "$ID" "$STATE" && INGESTED=$((INGESTED + 1))
done
FAILED=$(( ${#NEW[@]} - INGESTED ))

log "done: $INGESTED ingested, $FAILED failed"
