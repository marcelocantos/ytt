#!/usr/bin/env bats
# Tests for notify.sh: sink delivery, payload shape, dedup/re-notify policy,
# recovery notices, and the secret-permissions refusal.

load lib

setup() {
    # Deliberately NOT calling lib.bash's setup(): these tests drive notify.sh
    # directly rather than through ingest.sh, so they want the real notifier.
    SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    MOCKS_DIR="$SCRIPT_DIR/tests/mocks"
    PATH="$MOCKS_DIR:$PATH"

    export YOUTUBE_INGEST_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export YOUTUBE_INGEST_NOTIFY_BANNER=0
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
    mkdir -p "$XDG_CONFIG_HOME/ytt"

    WEBHOOK_FILE="$XDG_CONFIG_HOME/ytt/slack-webhook"
    printf 'https://hooks.slack.test/services/T000/B000/secret\n' > "$WEBHOOK_FILE"
    chmod 600 "$WEBHOOK_FILE"

    POST_LOG="$BATS_TEST_TMPDIR/posts"
    export MOCK_CURL_POST_LOG="$POST_LOG"
}

# Body goes in via a redirect, never a pipe: `printf ... | run cmd` puts `run`
# in a subshell, so the $status/$output it sets are lost to the test.
notify() {
    local vstatus="$1" subject="$2"; shift 2
    local body="$BATS_TEST_TMPDIR/body"
    if (( $# > 0 )); then printf '%s\n' "$@" > "$body"; else : > "$body"; fi
    run "$SCRIPT_DIR/notify.sh" "$vstatus" "$subject" < "$body"
}

# Backdate the recorded send time. `sed -i ''` is BSD-only and CI is Ubuntu,
# so rewrite via a temp file instead.
backdate_sent_at() {
    local state="$YOUTUBE_INGEST_STATE_DIR/notify-state"
    local when=$(( $(date -u +%s) - $1 * 86400 ))
    awk -v w="$when" '/^sent_at=/ {print "sent_at=" w; next} {print}' \
        "$state" > "$state.tmp"
    mv "$state.tmp" "$state"
}

posts() { cat "$POST_LOG" 2>/dev/null || true; }
post_count() {
    local n
    n="$(grep -c '^POST ' "$POST_LOG" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

@test "a problem posts to the Slack webhook with the subject and body" {
    notify problem "ytt ingest unhealthy: nothing to do" "channels config MISSING at /nope.yaml"

    [ "$status" -eq 0 ]
    [[ "$(posts)" == *"https://hooks.slack.test/services/T000/B000/secret"* ]]
    [[ "$(posts)" == *"ytt ingest unhealthy"* ]]
    [[ "$(posts)" == *"channels config MISSING"* ]]
}

@test "the payload is valid JSON even with quotes, newlines and em-dashes" {
    # Hand-rolled shell escaping into JSON is how alerting breaks on the day it
    # matters, so the payload must survive the punctuation real messages carry.
    notify problem 'unhealthy: "quoted" — dashed' 'line one' 'a "quoted" line' 'back\slash'

    [ "$status" -eq 0 ]
    payload="$(sed -n 's/^POST [^ ]* //p' "$POST_LOG" | tail -1)"
    # Parses as JSON, and the text round-trips intact.
    printf '%s' "$payload" | python3 -c '
import json, sys
text = json.load(sys.stdin)["text"]
assert "a \"quoted\" line" in text, text
assert "back\\slash" in text, text
assert "— dashed" in text, text
'
}

@test "the same problem does not re-alert every run" {
    notify problem "unhealthy: same thing" "channels config MISSING"
    [ "$(post_count)" -eq 1 ]

    notify problem "unhealthy: same thing" "channels config MISSING"
    [ "$status" -eq 0 ]
    [[ "$output" == *"staying quiet"* ]]
    [ "$(post_count)" -eq 1 ]
}

@test "a different problem alerts even while the first is unresolved" {
    notify problem "unhealthy: first" "channels config MISSING"
    notify problem "unhealthy: second" "index refresh FAILED"

    [ "$(post_count)" -eq 2 ]
    [[ "$(posts)" == *"index refresh FAILED"* ]]
}

@test "an unresolved problem re-alerts once the re-notify window passes" {
    notify problem "unhealthy: persistent" "channels config MISSING"
    [ "$(post_count)" -eq 1 ]

    # Backdate the recorded send by 8 days (default window is 7).
    backdate_sent_at 8

    notify problem "unhealthy: persistent" "channels config MISSING"
    [ "$(post_count)" -eq 2 ]
    [[ "$(posts)" == *"STILL BROKEN (8d)"* ]]
}

@test "re-notify can be disabled entirely" {
    notify problem "unhealthy: persistent" "channels config MISSING"
    backdate_sent_at 900

    YOUTUBE_INGEST_NOTIFY_RENOTIFY_DAYS=0 \
        run "$SCRIPT_DIR/notify.sh" problem "unhealthy: persistent" <<< "channels config MISSING"

    [ "$status" -eq 0 ]
    [[ "$output" == *"staying quiet"* ]]
    [ "$(post_count)" -eq 1 ]
}

@test "a healthy run after a problem sends exactly one recovery notice" {
    notify problem "unhealthy: broken" "channels config MISSING"
    [ "$(post_count)" -eq 1 ]

    notify ok "healthy: 3 ingested, 0 failed" "3 ingested, 0 failed"
    [ "$(post_count)" -eq 2 ]
    [[ "$(posts)" == *"RECOVERED"* ]]

    # Steady-state health is silent — an every-morning "all good" trains you to
    # ignore the channel, which defeats the alert that matters.
    notify ok "healthy: 0 ingested, 0 failed" "0 ingested, 0 failed"
    [ "$(post_count)" -eq 2 ]
}

@test "a healthy run with no prior problem is silent" {
    notify ok "healthy: nothing to do" "nothing to do"

    [ "$status" -eq 0 ]
    [ "$(post_count)" -eq 0 ]
}

@test "a group-readable webhook file is refused, not used" {
    chmod 644 "$WEBHOOK_FILE"

    notify problem "unhealthy: something" "detail"

    [ "$status" -eq 0 ]
    [[ "$output" == *"refusing to read"* ]]
    [[ "$output" == *"grants group/other access"* ]]
    [[ "$output" == *"chmod 600"* ]]
    [ "$(post_count)" -eq 0 ]
}

@test "an explicit webhook env var overrides the config file" {
    export YOUTUBE_INGEST_SLACK_WEBHOOK="https://hooks.slack.test/services/ENV/OVERRIDE/x"

    notify problem "unhealthy: something" "detail"

    [[ "$(posts)" == *"ENV/OVERRIDE"* ]]
    [[ "$(posts)" != *"B000/secret"* ]]
}

@test "a failing webhook is reported but never fails the caller" {
    # ingest.sh treats alerting as a side channel: a broken webhook must not
    # turn a successful ingest into a failed run.
    export MOCK_CURL_POST_FAIL=1

    notify problem "unhealthy: something" "detail"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Slack POST FAILED"* ]]
    [[ "$output" == *"NO sink delivered"* ]]
}

@test "no configured sink at all is reported loudly on stderr" {
    rm -f "$WEBHOOK_FILE"

    notify problem "unhealthy: something" "detail"

    [ "$status" -eq 0 ]
    [[ "$output" == *"NO sink delivered this alert"* ]]
}

@test "a bad status argument is rejected" {
    run "$SCRIPT_DIR/notify.sh" maybe "subject" < /dev/null

    [ "$status" -eq 2 ]
    [[ "$output" == *"must be 'problem' or 'ok'"* ]]
}
