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
#   Slack DM  (preferred) chat.postMessage with a bot token, to the user in
#             $YOUTUBE_INGEST_SLACK_DM. Token from $YOUTUBE_INGEST_SLACK_TOKEN,
#             else $YOUTUBE_INGEST_SLACK_TOKEN_FILE, else
#             $XDG_CONFIG_HOME/ytt/slack-token. Needs scope chat:write (plus
#             im:write to open the DM). A DM is the right shape for a personal
#             scheduler; it also survives channel reorganisation.
#
#             NOT the claude.ai Slack connector: that is a Claude *session*
#             capability, and launchd runs bash. Measured 2026-07-26, a fresh
#             `claude -p` had the Slack tools in 1 of 6 runs. Alerting must work
#             exactly when things are broken, so it gets its own credential and
#             a plain HTTPS call with no LLM in the path.
#
#   Slack ch  (fallback) POST to an incoming-webhook URL from
#             $YOUTUBE_INGEST_SLACK_WEBHOOK / _FILE / the default
#             $XDG_CONFIG_HOME/ytt/slack-webhook. Webhooks are bound to one
#             channel at creation and cannot DM.
#
#           Both are secrets and MUST NOT be committed: keep them in files,
#           mode 600. A group/world-readable file is refused rather than used,
#           so a careless `chmod` fails loudly here instead of quietly leaking
#           a credential that can post to the workspace.
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

# ---- Slack -------------------------------------------------------------------
# Read a secret from a file, refusing it if the permissions are loose. This is
# the one moment we can catch a leaked credential, and a loud refusal beats a
# quiet compromise.
#
# Probing the mode portably needs care: `stat -c` is GNU and `stat -f` is BSD,
# but GNU's `-f` means "filesystem status" and EXITS 0 while printing the format
# string back, so a naive `-f || -c` chain silently yields garbage on Linux.
# Hence: try GNU, keep the answer only if it looks like an octal mode, then BSD.
read_secret() {
    local f="$1" mode
    [[ -f "$f" ]] || return 1
    mode="$(stat -c '%a' "$f" 2>/dev/null || true)"
    [[ "$mode" =~ ^[0-7]+$ ]] || mode="$(stat -f '%Lp' "$f" 2>/dev/null || true)"
    [[ "$mode" =~ ^[0-7]+$ ]] || mode=""
    if [[ -z "$mode" ]]; then
        # Undeterminable mode: proceed rather than block the alert, but say so —
        # refusing here would mean never alerting at all on such a platform.
        echo "notify: cannot determine permissions of $f; using it anyway" >&2
    elif (( 8#$mode & 8#77 )); then
        echo "notify: refusing to read $f — mode $mode grants group/other access; run: chmod 600 $f" >&2
        return 1
    fi
    head -1 "$f" | tr -d '[:space:]'
}

# JSON is built by python3, never by shell string-splicing: the body carries
# newlines, quotes and em-dashes, and hand-rolled escaping of those is exactly
# how alerting breaks on the day it matters.
json_payload() {
    SLACK_TEXT="$MESSAGE" SLACK_CHANNEL="$1" python3 -c \
        'import json, os; print(json.dumps({"channel": os.environ["SLACK_CHANNEL"], "text": os.environ["SLACK_TEXT"]}))'
}

TOKEN_FILE="${YOUTUBE_INGEST_SLACK_TOKEN_FILE:-$CONFIG_DIR/slack-token}"
WEBHOOK_FILE="${YOUTUBE_INGEST_SLACK_WEBHOOK_FILE:-$CONFIG_DIR/slack-webhook}"
SLACK_DM="${YOUTUBE_INGEST_SLACK_DM:-}"

TOKEN="${YOUTUBE_INGEST_SLACK_TOKEN:-}"
[[ -n "$TOKEN" ]] || TOKEN="$(read_secret "$TOKEN_FILE" || true)"

# Preferred sink: a bot token posting a direct message. A DM is the right shape
# for a personal scheduler — an incoming webhook is bound to one channel chosen
# at creation time and cannot DM at all.
#
# Deliberately NOT used here: the claude.ai Slack connector. It is a Claude
# *session* capability; a fresh `claude -p` run showed the Slack tools once out
# of six invocations and launchd runs bash, not Claude. Alerting must work
# exactly when things are broken, so it gets its own credential and a plain
# HTTPS call with no LLM in the path.
if [[ -n "$TOKEN" && -n "$SLACK_DM" ]]; then
    if ! command -v curl >/dev/null; then
        echo "notify: curl unavailable; cannot reach Slack" >&2
    else
        # chat.postMessage returns HTTP 200 with {"ok":false,"error":"..."} for
        # logical failures (bad token, missing scope, unknown user), so the HTTP
        # status alone is not success — the body has to be parsed. Surface
        # Slack's error verbatim; it names the exact misconfiguration.
        resp="$(curl -sS --max-time 20 -X POST \
            -H "Authorization: Bearer $TOKEN" \
            -H 'Content-Type: application/json; charset=utf-8' \
            --data "$(json_payload "$SLACK_DM")" \
            https://slack.com/api/chat.postMessage 2>/dev/null || true)"
        slack_err="$(printf '%s' "$resp" | python3 -c \
            'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unparseable response"); raise SystemExit
print("" if d.get("ok") else (d.get("error") or "unknown error"))' 2>/dev/null || printf 'unparseable response')"
        if [[ -z "$slack_err" ]]; then
            echo "notify: sent Slack DM to $SLACK_DM"
            DELIVERED=true
        else
            echo "notify: Slack DM FAILED ($slack_err)" >&2
        fi
    fi
fi

# Fallback sink: an incoming webhook, for a channel rather than a DM.
if ! $DELIVERED; then
    WEBHOOK="${YOUTUBE_INGEST_SLACK_WEBHOOK:-}"
    [[ -n "$WEBHOOK" ]] || WEBHOOK="$(read_secret "$WEBHOOK_FILE" || true)"
    if [[ -n "$WEBHOOK" ]] && command -v curl >/dev/null; then
        if curl -fsS --max-time 20 -X POST \
                -H 'Content-Type: application/json' \
                --data "$(json_payload "")" "$WEBHOOK" -o /dev/null; then
            echo "notify: posted to Slack webhook"
            DELIVERED=true
        else
            echo "notify: Slack webhook POST FAILED (unreachable or rejected)" >&2
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
