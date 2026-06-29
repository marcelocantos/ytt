#!/usr/bin/env bash
# Ingest a single YouTube video by ID into the knowledge base.
# Intended to be invoked in parallel by ingest.sh; safe to run standalone.
#
# Usage: ingest-one.sh <video-id>
#
# Honours $YOUTUBE_INGEST_ROOT (default ~/think/knowledge/youtube).
# Appends "<id>" to $ROOT/.processed on success.
# Logs to $ROOT/.ingest.log.
#
# Rate limiting (shared across all parallel workers — keeps YouTube from
# IP-blocking this egress IP for bursty access). Consecutive YouTube requests
# are spaced by a random delay drawn from a configurable window; randomising
# the gap avoids a fixed, fingerprintable cadence:
#   $YOUTUBE_INGEST_FETCH_INTERVAL_MIN  min seconds between requests (default 180)
#   $YOUTUBE_INGEST_FETCH_INTERVAL_MAX  max seconds between requests (default 420)
#   $YOUTUBE_INGEST_FETCH_RETRIES       transcript attempts on IP-block (default 3)

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

# Hard-timeout wrapper for the network / LLM calls below. A stalled connection
# — common when the laptop sleeps mid-run — otherwise blocks a worker, and thus
# the whole run, and thus every future run (launchd won't start a second while
# one is alive), indefinitely: exactly what wedged the pipeline for 4 days.
# macOS lacks GNU timeout; Homebrew coreutils ships it as `timeout`/`gtimeout`.
# Falls back to no timeout only if neither exists. Exit 124 ⇒ timed out.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
with_timeout() {
    local secs="$1"; shift
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" --kill-after=10 "$secs" "$@"
    else
        "$@"
    fi
}

# --- Cross-worker YouTube request pacing ---------------------------------
# YouTube blocks the egress IP ("IpBlocked") when it sees a burst of
# transcript-API requests, and the block is sticky for minutes — so one burst
# fails every remaining fetch in a run. To stay far under any burst threshold,
# serialise YouTube requests across ALL parallel workers and space consecutive
# requests by a random delay (default 3–7 minutes).
#
# Mechanism: a shared stamp file holds the epoch time of the next reservable
# slot. Each worker briefly takes an atomic mkdir lock, reserves the next slot
# (stamp += a fresh random interval), releases the lock, then sleeps OUTSIDE
# the lock until its slot. The lock is held only for a few file ops — never
# across the multi-minute sleep — so workers reserve staggered slots and wait
# them out concurrently instead of piling up spinning on the lock. Portable:
# no flock (absent on macOS); leak detection uses find -mmin, not BSD stat.
FETCH_MIN="${YOUTUBE_INGEST_FETCH_INTERVAL_MIN:-180}"   # 3 minutes
FETCH_MAX="${YOUTUBE_INGEST_FETCH_INTERVAL_MAX:-420}"   # 7 minutes
GATE="$ROOT/.fetch.lock"      # atomic mkdir mutex, held only for a reservation
STAMP="$ROOT/.fetch.stamp"    # epoch seconds of the next reservable request slot

throttle() {
    # Take the lock to reserve a slot. mkdir is atomic, so exactly one worker
    # reserves at a time. Any lock older than a minute is a leak from a worker
    # killed mid-reservation (we never hold it that long) — steal it.
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
    # If the line is idle (last slot already in the past), go now; the very
    # first request of a run therefore fires immediately.
    if (( target < now )); then
        target=$now
    fi
    printf '%s\n' "$target" >"$STAMP"
    rm -rf "$GATE"
    # Wait out the reservation outside the lock so peers can reserve their own
    # (later) slots and sleep concurrently.
    local sleep_for=$(( target - now ))
    if (( sleep_for > 0 )); then
        log "pacing: holding ${sleep_for}s for next YouTube request slot"
        sleep "$sleep_for"
    fi
}

# The transcript is bulky source material consumed once at ingest. Park
# it in a dotfolder so Obsidian skips it (avoids 16 graph nodes labelled
# "transcript") while still keeping it on disk for re-runs and review.
# JSON preserves the upstream library's full payload (per-segment timing,
# language metadata, auto-generated flag) — pretty-printed via jq so it
# stays readable when opened directly.
mkdir -p "$DIR/.transcript"

log "start"

set -o pipefail

# Fetch the transcript, throttled and with bounded retries on IP-block. A
# block is transient (a cooldown on the egress IP), so back off and retry a
# few times. Non-block failures (no transcript, private/removed video) are
# permanent — fail fast rather than burn retries. On final failure the video
# stays out of .processed and is retried on the next run. stderr is captured
# (not piped) so we can classify the failure; stdout goes to a raw temp that
# jq then pretty-prints into the kept transcript.json.
RAW="$DIR/.transcript/transcript.raw.json"
attempt=0
max_attempts="${YOUTUBE_INGEST_FETCH_RETRIES:-3}"
while :; do
    throttle
    rc=0
    err=$(with_timeout 120 ytt --json "$URL" 2>&1 >"$RAW") || rc=$?
    if (( rc == 0 )); then
        break
    fi
    printf '%s\n' "$err" >>"$LOG"
    attempt=$((attempt + 1))
    # A timeout (124, a stalled connection) or an IP-block is transient — retry
    # after the next pacing slot. Anything else (no transcript, private/removed
    # video) is permanent — fail fast rather than burn retries.
    if { (( rc != 124 )) && ! grep -qiE 'blocked|too ?many ?requests|429' <<<"$err"; } \
        || (( attempt >= max_attempts )); then
        log "ytt failed (rc=$rc); cleaning up"
        rm -rf "$DIR"
        exit 1
    fi
    log "transcript fetch failed (rc=$rc); will retry ($attempt/$max_attempts) after the next pacing slot"
done

if ! jq . "$RAW" >"$DIR/.transcript/transcript.json"; then
    log "transcript json malformed; cleaning up"
    rm -rf "$DIR"
    exit 1
fi
rm -f "$RAW"

# Pipe failures cascade via pipefail so a yt-dlp/jq breakage produces a
# non-zero status (rather than silently writing a 0-byte meta.json that
# poisons the synopsis step). The metadata fetch is NOT separately paced: it
# rides immediately after the (paced) transcript fetch, so each video makes a
# tight request pair every few minutes rather than two multi-minute waits —
# same gentle aggregate rate, half the wall-clock cost.
if ! with_timeout 120 yt-dlp --skip-download --print-json "$URL" 2>>"$LOG" \
    | jq '{id, title, uploader, channel, channel_id, upload_date,
           duration, view_count, description, webpage_url, tags}' \
    >"$DIR/meta.json"; then
    log "meta fetch failed; cleaning up"
    rm -rf "$DIR"
    exit 1
fi

TITLE=$(jq -r '.title // "(unknown)"' "$DIR/meta.json" 2>/dev/null || echo "(unknown)")

PROMPT=$(cat <<EOF
Read the transcript at $DIR/.transcript/transcript.json (YouTube video:
"$TITLE", $URL). The file is the full youtube-transcript-api payload:
a JSON object with video_id, language, language_code, is_generated, and
a snippets array of {text, start, duration}. Join snippet text in order
for the prose; you may cite [mm:ss] timestamps (from snippet.start) in
Key Takeaways when a moment is worth pinning to.

Produce a detailed synopsis and key takeaways following the /ytt skill's
output format (multi-paragraph synopsis covering full content in logical
order, then a bulleted Key Takeaways list).

Choose a topic-based filename slug for the output. Requirements:

- 2–6 words, kebab-case, lowercase ASCII, ending in ".md"
- Describes the actual subject matter — not the literal video title
  (titles are often clickbaity). Read like a useful node label in an
  Obsidian graph view; reading the slug alone should hint at the topic.
- Favour the substantive topic over personalities/sensationalism.
- Must NOT begin with "transcript" (reserved).

Write the synopsis to \$DIR/<slug>.md (where \$DIR is $DIR), with this
exact structure:

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

Do not write anything else to disk. Reply with just the slug filename
(e.g. "claude-desktop-project-features.md") when finished — nothing else.
EOF
)

# Generate the synopsis. Capture Claude's output so a spend/usage-limit
# refusal — which will hit every remaining video too — can be told apart from
# an ordinary per-video failure. On the spend limit, exit 255: xargs treats
# 255 as "stop, read no more input", so the parent stops dispatching the rest
# of the batch instead of paced-fetching transcripts for hours only to fail
# each synopsis. The undispatched videos simply retry once the budget frees.
SYNOPSIS_OUT="$DIR/.transcript/synopsis.out"
if ! printf '%s\n' "$PROMPT" | with_timeout 600 claude -p \
    --permission-mode acceptEdits \
    --allowedTools "Read,Write" \
    --add-dir "$DIR" >"$SYNOPSIS_OUT" 2>&1; then
    cat "$SYNOPSIS_OUT" >>"$LOG"
    if grep -qiE 'monthly spend limit|usage limit|spend(ing)? limit|claude\.ai/settings/usage' "$SYNOPSIS_OUT"; then
        : > "$ROOT/.spend-limit"   # marker: tell the parent the run was cut short
        log "claude synopsis hit the spend limit; aborting run so the rest defers (exit 255 stops xargs)"
        rm -rf "$DIR"
        exit 255
    fi
    log "claude synopsis failed; cleaning up"
    rm -rf "$DIR"
    exit 1
fi
cat "$SYNOPSIS_OUT" >>"$LOG"
rm -f "$SYNOPSIS_OUT"

# Locate the synopsis file Claude wrote (any *.md other than transcript*).
SYNOPSIS=$(find "$DIR" -maxdepth 1 -type f -name '*.md' \
    ! -name 'transcript*' -print -quit)

if [[ -z "$SYNOPSIS" || ! -s "$SYNOPSIS" ]]; then
    log "synopsis file missing or empty; cleaning up"
    rm -rf "$DIR"
    exit 1
fi

# Atomic single-line append.
printf '%s\n' "$ID" >>"$STATE"
log "ingested ($TITLE)"
