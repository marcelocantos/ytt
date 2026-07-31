# Shared setup for playlist-ingest bats tests.
#
# Each test gets its own isolated ROOT under $BATS_TEST_TMPDIR and a
# PATH that prepends $TESTS_DIR/mocks so yt-dlp / ytt / claude /
# build-index.sh are all stubbed.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TESTS_DIR="$SCRIPT_DIR/tests"
    MOCKS_DIR="$TESTS_DIR/mocks"

    # Parts of the pipeline are now subcommands of the Go binary. Point the
    # tests at the built binary and fail loudly if it is absent: silently
    # skipping would let these tests pass while exercising nothing.
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    YTT_GO_BIN="$REPO_ROOT/ytt"
    export YTT_GO_BIN
    if [[ ! -x "$YTT_GO_BIN" ]]; then
        printf 'lib.bash: %s missing or not executable; run `make build` first\n' \
            "$YTT_GO_BIN" >&2
        return 1
    fi

    ROOT="$BATS_TEST_TMPDIR/youtube"
    mkdir -p "$ROOT"

    export YOUTUBE_INGEST_ROOT="$ROOT"
    export YOUTUBE_INGEST_PLAYLIST="https://example.test/playlist?list=TESTLIST"
    export YOUTUBE_INGEST_CONCURRENCY=2
    export YOUTUBE_CHANNELS_FILE="$BATS_TEST_TMPDIR/channels.yaml"

    # Isolate all alert machinery. Without this, tests write to the real
    # ~/.local/state/ytt (poisoning the dedup state that suppresses genuine
    # alerts) and fire real notification-centre banners.
    export YOUTUBE_INGEST_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export YOUTUBE_INGEST_NOTIFY_BANNER=0
    unset YOUTUBE_INGEST_SLACK_WEBHOOK
    export YOUTUBE_INGEST_SLACK_WEBHOOK_FILE="$BATS_TEST_TMPDIR/no-such-webhook"
    # ytt reports events; blurter delivers them. These tests assert on WHAT ytt
    # reports, using a mock blurter. Delivery, dedup and recovery behaviour are
    # blurter's own test suite's responsibility — that separation is the point.
    BLURTER_LOG="$BATS_TEST_TMPDIR/blurter-calls"
    export BLURTER_LOG
    export YOUTUBE_INGEST_BLURTER_BIN="$MOCKS_DIR/blurter"

    # Disable request pacing in tests — ingest-one's throttle otherwise sleeps
    # a random 3–7 min per fetch. MIN=MAX=0 ⇒ zero-length reservation, no sleep.
    export YOUTUBE_INGEST_FETCH_INTERVAL_MIN=0
    export YOUTUBE_INGEST_FETCH_INTERVAL_MAX=0

    # Empty channels file by default; tests opt in via channels_with().
    : > "$YOUTUBE_CHANNELS_FILE"

    # Empty playlist by default.
    export MOCK_YT_DLP_PLAYLIST_IDS=""

    # Reset failure injection.
    unset MOCK_CLAUDE_FAIL MOCK_YT_DLP_META_FAIL MOCK_YTT_FAIL
    unset MOCK_YT_DLP_PLAYLIST_FAIL MOCK_YT_DLP_CHANNEL_FAIL
    unset MOCK_YT_DLP_CHANNEL_TRUNCATE MOCK_CURL_FAIL MOCK_CURL_FAIL_COUNT
    unset YOUTUBE_INGEST_YTT_BIN YOUTUBE_INGEST_CLAUDE_BIN

    PATH="$MOCKS_DIR:$PATH"
}

# Set the playlist's IDs (newest-first; ingest.sh applies --playlist-reverse).
set_playlist() {
    MOCK_YT_DLP_PLAYLIST_IDS="$*"
    export MOCK_YT_DLP_PLAYLIST_IDS
}

# Set the channel feed for a handle. Args: <handle> <id1> <id2> ... (newest-first).
set_channel() {
    local handle="$1"; shift
    local var="MOCK_YT_DLP_CHANNEL_$(printf '%s' "$handle" | tr -c '[:alnum:]' _)"
    eval "export $var=\"\$*\""
}

# Write a channels.yaml referencing the given handles. Quotes each handle
# so a leading `@` doesn't trip the YAML parser.
channels_with() {
    {
        printf 'channels:\n'
        for h in "$@"; do
            printf '  - handle: "%s"\n' "$h"
        done
    } > "$YOUTUBE_CHANNELS_FILE"
}

# Pre-record an ID as already processed.
mark_processed() {
    local id
    for id in "$@"; do
        printf '%s\n' "$id" >> "$ROOT/.processed"
    done
}

# Set a channel cursor file directly. Args: <handle> <id>.
set_cursor() {
    mkdir -p "$ROOT/.channels"
    printf '%s\n' "$2" > "$ROOT/.channels/$1"
}

# Run ingest.sh capturing stdout+stderr.
run_ingest() {
    run "$SCRIPT_DIR/ingest.sh" "$@"
}

# Run ingest-one.sh for a single video ID.
run_ingest_one() {
    run "$SCRIPT_DIR/ingest-one.sh" "$@"
}

# Everything ytt reported to blurter this test (empty when nothing was reported).
reported() {
    cat "$BLURTER_LOG" 2>/dev/null || true
}

# Backdate the liveness stamp so the staleness check trips. Args: <days-ago>.
set_last_ingest_days_ago() {
    mkdir -p "$YOUTUBE_INGEST_STATE_DIR"
    printf '%s\n' "$(( $(date -u +%s) - $1 * 86400 ))" \
        > "$YOUTUBE_INGEST_STATE_DIR/last-ingest"
}

# Point channel-config resolution at an isolated XDG config dir with no
# explicit $YOUTUBE_CHANNELS_FILE, so the search order itself is under test.
# Args: optional handles to write into $XDG_CONFIG_HOME/ytt/channels.yaml.
use_xdg_channels_config() {
    unset YOUTUBE_CHANNELS_FILE
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
    mkdir -p "$XDG_CONFIG_HOME/ytt"
    if (( $# > 0 )); then
        {
            printf 'channels:\n'
            for h in "$@"; do printf '  - handle: "%s"\n' "$h"; done
        } > "$XDG_CONFIG_HOME/ytt/channels.yaml"
    fi
}

# Resolve to a channels file that does not exist, without falling through to
# the copy beside the script (a dev checkout has a real one, which would make
# these tests read the author's live channel list).
no_channels_config() {
    export YOUTUBE_CHANNELS_FILE="$BATS_TEST_TMPDIR/absent-channels.yaml"
    rm -f "$YOUTUBE_CHANNELS_FILE"
}
