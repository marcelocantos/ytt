# Shared setup for playlist-ingest bats tests.
#
# Each test gets its own isolated ROOT under $BATS_TEST_TMPDIR and a
# PATH that prepends $TESTS_DIR/mocks so yt-dlp / ytt / claude /
# build-index.sh are all stubbed.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TESTS_DIR="$SCRIPT_DIR/tests"
    MOCKS_DIR="$TESTS_DIR/mocks"

    ROOT="$BATS_TEST_TMPDIR/youtube"
    mkdir -p "$ROOT"

    export YOUTUBE_INGEST_ROOT="$ROOT"
    export YOUTUBE_INGEST_PLAYLIST="https://example.test/playlist?list=TESTLIST"
    export YOUTUBE_INGEST_CONCURRENCY=2
    export YOUTUBE_CHANNELS_FILE="$BATS_TEST_TMPDIR/channels.yaml"

    # Empty channels file by default; tests opt in via channels_with().
    : > "$YOUTUBE_CHANNELS_FILE"

    # Empty playlist by default.
    export MOCK_YT_DLP_PLAYLIST_IDS=""

    # Reset failure injection.
    unset MOCK_CLAUDE_FAIL MOCK_YT_DLP_META_FAIL MOCK_YTT_FAIL

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
