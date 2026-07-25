#!/usr/bin/env bash
# Out-of-band alerting for the scheduled ingest.
#
# Usage: notify.sh <status> <subject>   (body lines on stdin)
#   status   problem — something is wrong; alert.
#            ok      — the run was healthy. Sends a recovery notice ONLY if the
#                      previous alert was a problem, and is otherwise silent.
#   subject  one-line summary; becomes the Slack message title / banner title.
#
# Why this exists: a scheduled job that can only complain into its own log
# file fails silently by construction — nobody tails a log daily. The ingest
# pipeline spent 15 days (2026-07-10 → 07-26) reporting a cheerful "nothing to
# do" every night with channel discovery entirely disabled, and nothing
# surfaced it. Exit codes alone were not enough: launchd records the code and
# tells no one.
#
# Sinks (all configured ones are attempted; the first success is enough for the
# alert to count as delivered):
#
#   Slack   POST to an incoming-webhook URL, taken from the first of:
#             $YOUTUBE_INGEST_SLACK_WEBHOOK      (URL, for ad-hoc use)
#             $YOUTUBE_INGEST_SLACK_WEBHOOK_FILE (file containing the URL)
#             $XDG_CONFIG_HOME/ytt/slack-webhook (default location)
#           The URL is a secret and MUST NOT be committed: keep it in the file,
#           mode 600. A file whose permissions are group/world-readable is
#           refused rather than used, so a careless `chmod` fails loudly here
#           instead of quietly leaking a webhook that can post to the channel.
#
#   macOS   A notification-centre banner via osascript. Zero configuration, so
#           it works out of the box, but only reaches you at the machine —
#           hence Slack for anything that matters. Set
#           $YOUTUBE_INGEST_NOTIFY_BANNER=0 to suppress.
#
# Dedup: the same problem recurring every night must not produce a nightly
# alert, and must not be silently dropped forever either. State lives in
# $YOUTUBE_INGEST_STATE_DIR/notify-state; an alert is sent when the problem
# digest CHANGES, or when $YOUTUBE_INGEST_NOTIFY_RENOTIFY_DAYS (default 7)
# have passed since the last send for the same digest. Set that to 0 to never
# re-notify an unchanged problem.

set -euo pipefail

STATUS="${1:-}"
SUBJECT="${2:-}"
if [[ -z "$STATUS" || -z "$SUBJECT" ]]; then
    echo "usage: notify.sh <problem|ok> <subject>   (body on stdin)" >&2
    exit 2
fi
case "$STATUS" in
    problem|ok) ;;
    *) echo "notify.sh: status must be 'problem' or 'ok', got: $STATUS" >&2; exit 2 ;;
esac

STATE_DIR="${YOUTUBE_INGEST_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ytt}"
STATE_FILE="$STATE_DIR/notify-state"
RENOTIFY_DAYS="${YOUTUBE_INGEST_NOTIFY_RENOTIFY_DAYS:-7}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ytt"
mkdir -p "$STATE_DIR"

BODY="$(cat || true)"
NOW="$(date -u +%s)"
STAMP="$(date -u +%FT%TZ)"

# Dedup key: the status plus the body, so "same problem again" is recognised
# but "a new problem appeared alongside it" is not suppressed.
# sha256sum on Linux, shasum on macOS — CI runs these tests on Ubuntu.
if command -v sha256sum >/dev/null; then
    DIGEST="$(printf '%s\n%s' "$STATUS" "$BODY" | sha256sum | cut -d' ' -f1)"
else
    DIGEST="$(printf '%s\n%s' "$STATUS" "$BODY" | shasum -a 256 | cut -d' ' -f1)"
fi

PREV_DIGEST=""
PREV_SENT=0
PREV_STATUS=""
if [[ -f "$STATE_FILE" ]]; then
    # Format: one "key=value" per line — trivially greppable, no parser needed.
    PREV_DIGEST="$(sed -n 's/^digest=//p' "$STATE_FILE" | tail -1)"
    PREV_SENT="$(sed -n 's/^sent_at=//p' "$STATE_FILE" | tail -1)"
    PREV_STATUS="$(sed -n 's/^status=//p' "$STATE_FILE" | tail -1)"
    [[ "$PREV_SENT" =~ ^[0-9]+$ ]] || PREV_SENT=0
fi

record_state() {
    cat > "$STATE_FILE" <<EOF
status=$STATUS
digest=$DIGEST
sent_at=$1
updated_at=$STAMP
EOF
}

# A healthy run is normally silent. It speaks up only to close the loop on a
# problem it previously reported — an alert you never see resolved trains you
# to ignore the channel.
if [[ "$STATUS" == ok ]]; then
    if [[ "$PREV_STATUS" != problem ]]; then
        record_state "$PREV_SENT"
        exit 0
    fi
    SUBJECT="RECOVERED — $SUBJECT"
else
    if [[ "$DIGEST" == "$PREV_DIGEST" ]] && (( PREV_SENT > 0 )); then
        age_days=$(( (NOW - PREV_SENT) / 86400 ))
        # RENOTIFY_DAYS=0 disables re-notification: stay quiet until the
        # problem itself changes.
        if (( RENOTIFY_DAYS == 0 || age_days < RENOTIFY_DAYS )); then
            echo "notify: same problem already alerted ${age_days}d ago (re-notify after ${RENOTIFY_DAYS}d); staying quiet"
            record_state "$PREV_SENT"
            exit 0
        fi
        SUBJECT="STILL BROKEN (${age_days}d) — $SUBJECT"
    fi
fi

MESSAGE="$SUBJECT"
[[ -n "$BODY" ]] && MESSAGE="$MESSAGE"$'\n'"$BODY"

DELIVERED=false

# ---- Slack ------------------------------------------------------------------
WEBHOOK=""
WEBHOOK_FILE="${YOUTUBE_INGEST_SLACK_WEBHOOK_FILE:-$CONFIG_DIR/slack-webhook}"
if [[ -n "${YOUTUBE_INGEST_SLACK_WEBHOOK:-}" ]]; then
    WEBHOOK="$YOUTUBE_INGEST_SLACK_WEBHOOK"
elif [[ -f "$WEBHOOK_FILE" ]]; then
    # Refuse a group/world-readable secret rather than use it: this is the one
    # moment we can catch a leaked webhook, and a loud refusal beats a quiet
    # compromise.
    #
    # Probing the mode portably needs care: `stat -c` is GNU and `stat -f` is
    # BSD, but GNU's `-f` means "filesystem status" and EXITS 0 while printing
    # the format string back, so a naive `-f || -c` chain silently yields
    # garbage on Linux. Hence: try GNU, keep the answer only if it looks like an
    # octal mode, then try BSD.
    mode="$(stat -c '%a' "$WEBHOOK_FILE" 2>/dev/null || true)"
    [[ "$mode" =~ ^[0-7]+$ ]] || mode="$(stat -f '%Lp' "$WEBHOOK_FILE" 2>/dev/null || true)"
    [[ "$mode" =~ ^[0-7]+$ ]] || mode=""
    if [[ -z "$mode" ]]; then
        # Undeterminable mode: proceed rather than block the alert, but say so —
        # refusing here would mean never alerting at all on this platform.
        echo "notify: cannot determine permissions of $WEBHOOK_FILE; using it anyway" >&2
        WEBHOOK="$(head -1 "$WEBHOOK_FILE" | tr -d '[:space:]')"
    elif (( 8#$mode & 8#77 )); then
        echo "notify: refusing to read $WEBHOOK_FILE — mode $mode grants group/other access; run: chmod 600 $WEBHOOK_FILE" >&2
    else
        WEBHOOK="$(head -1 "$WEBHOOK_FILE" | tr -d '[:space:]')"
    fi
fi

if [[ -n "$WEBHOOK" ]]; then
    if ! command -v curl >/dev/null; then
        echo "notify: curl unavailable; cannot post to Slack" >&2
    else
        # Build the JSON with a heredoc-free python one-liner: the body contains
        # newlines, quotes, and em-dashes, and hand-rolled shell escaping of
        # those into JSON is exactly how alerting breaks on the day it matters.
        payload="$(SLACK_TEXT="$MESSAGE" python3 -c \
            'import json, os; print(json.dumps({"text": os.environ["SLACK_TEXT"]}))')"
        if curl -fsS --max-time 20 -X POST \
                -H 'Content-Type: application/json' \
                --data "$payload" "$WEBHOOK" -o /dev/null; then
            echo "notify: posted to Slack"
            DELIVERED=true
        else
            echo "notify: Slack POST FAILED (webhook unreachable or rejected)" >&2
        fi
    fi
fi

# ---- macOS banner -----------------------------------------------------------
if [[ "${YOUTUBE_INGEST_NOTIFY_BANNER:-1}" != 0 ]] && command -v osascript >/dev/null; then
    # Only the subject goes in the banner; notification centre truncates
    # aggressively and the full detail is in the log and the Slack message.
    if BANNER_TITLE="ytt ingest" BANNER_TEXT="$SUBJECT" osascript \
            -e 'display notification (system attribute "BANNER_TEXT") with title (system attribute "BANNER_TITLE")' \
            >/dev/null 2>&1; then
        echo "notify: banner shown"
        DELIVERED=true
    fi
fi

if ! $DELIVERED; then
    echo "notify: NO sink delivered this alert — configure a Slack webhook at $WEBHOOK_FILE (chmod 600)" >&2
fi

# Record the send even when no sink was reachable: retrying an undeliverable
# alert every night just fills the log. The problem itself is still in the
# ingest log and still reflected in the exit code.
record_state "$NOW"

# Never fail the caller: ingest.sh treats alerting as a side channel, and a
# broken webhook must not turn a successful ingest into a failed run.
exit 0
