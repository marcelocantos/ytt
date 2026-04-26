#!/usr/bin/env bash
# Ingest a single YouTube video by ID into the knowledge base.
# Intended to be invoked in parallel by ingest.sh; safe to run standalone.
#
# Usage: ingest-one.sh <video-id>
#
# Honours $YOUTUBE_INGEST_ROOT (default ~/think/knowledge/youtube).
# Appends "<id>" to $ROOT/.processed on success.
# Logs to $ROOT/.ingest.log.

set -euo pipefail

ID="${1:?video id required}"
ROOT="${YOUTUBE_INGEST_ROOT:-$HOME/think/knowledge/youtube}"
STATE="$ROOT/.processed"
LOG="$ROOT/.ingest.log"
DIR="$ROOT/$ID"
URL="https://www.youtube.com/watch?v=$ID"

log() {
    # Single-shot printf is atomic for short lines (< PIPE_BUF) on POSIX,
    # so concurrent workers can append to the same log safely.
    printf '[%s] [%s] %s\n' "$(date -u +%H:%M:%SZ)" "$ID" "$*" >>"$LOG"
}

mkdir -p "$DIR"

log "start"

if ! ytt "$URL" >"$DIR/transcript.md" 2>>"$LOG"; then
    log "ytt failed; cleaning up"
    rm -rf "$DIR"
    exit 1
fi

yt-dlp --skip-download --print-json "$URL" 2>>"$LOG" \
    | jq '{id, title, uploader, channel, channel_id, upload_date,
           duration, view_count, description, webpage_url, tags}' \
    >"$DIR/meta.json" || log "meta fetch failed (non-fatal)"

TITLE=$(jq -r '.title // "(unknown)"' "$DIR/meta.json" 2>/dev/null || echo "(unknown)")

PROMPT=$(cat <<EOF
Read the transcript at $DIR/transcript.md (YouTube video: "$TITLE", $URL).

Produce a detailed synopsis and key takeaways following the /ytt skill's
output format (multi-paragraph synopsis covering full content in logical
order, then a bulleted Key Takeaways list).

Write the result to $DIR/synopsis.md as markdown, with this exact structure:

  # $TITLE

  Source: $URL

  **TL;DR**: <one sentence — what the video is about and its central
  point. Self-contained: a reader scanning a list of TL;DRs should be
  able to decide whether to open this one. Single line, no line breaks.>

  ## Synopsis

  <multi-paragraph synopsis as described above>

  ## Key Takeaways

  <bulleted list>

The TL;DR line is consumed by an index generator — keep it on a single
line, prefixed exactly with "**TL;DR**: ".

Do not write anything else to disk. Reply with just "done" when finished.
EOF
)

if ! printf '%s\n' "$PROMPT" | claude -p \
    --permission-mode acceptEdits \
    --allowedTools "Read,Write" \
    --add-dir "$DIR" >>"$LOG" 2>&1; then
    log "claude synopsis failed"
    exit 1
fi

if [[ ! -s "$DIR/synopsis.md" ]]; then
    log "synopsis.md missing or empty"
    exit 1
fi

# Atomic single-line append.
printf '%s\n' "$ID" >>"$STATE"
log "ingested ($TITLE)"
