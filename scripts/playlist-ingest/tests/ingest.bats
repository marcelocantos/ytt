#!/usr/bin/env bats
# Tests for ingest.sh: orphan sweep, stale-cursor recovery, deferred
# cursor advance, and KB index regeneration.

load lib

@test "orphan sweep: stale dir without .processed entry is reclaimed and re-ingested" {
    # Arrange: pre-create an orphan dir for VID100----- with junk content.
    mkdir -p "$ROOT/VID100-----/.transcript"
    : > "$ROOT/VID100-----/meta.json"
    set_playlist "VID100-----"

    # Act
    run_ingest

    # Assert: orphan log fired, video re-ingested cleanly.
    [ "$status" -eq 0 ]
    [[ "$output" == *"orphan dirs from failed prior runs (queued for retry): VID100-----"* ]]
    grep -Fxq -- "VID100-----" "$ROOT/.processed"
    [ -f "$ROOT/VID100-----/mock-synopsis-VID100-----.md" ]
}

@test "orphan sweep: dir already in .processed is left alone" {
    mkdir -p "$ROOT/VID101-----"
    : > "$ROOT/VID101-----/mock-synopsis-VID101-----.md"
    mark_processed "VID101-----"
    set_playlist ""

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" != *"orphan dirs from failed prior runs"* ]]
    [ -d "$ROOT/VID101-----" ]
}

@test "stale cursor (not in .processed): walk proceeds past it; videos recovered" {
    channels_with "@stalechan"
    set_channel stalechan VIDA------- VIDB------- VIDC------- VIDD-------
    # Cursor points at VIDB------- but VIDB------- isn't in .processed — speculative leftover.
    set_cursor stalechan VIDB-------

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"cursor VIDB------- not in .processed; treating as stale"* ]]
    # All four feed entries should be queued (none in .processed yet).
    grep -Fxq -- "VIDA-------" "$ROOT/.processed"
    grep -Fxq -- "VIDB-------" "$ROOT/.processed"
    grep -Fxq -- "VIDC-------" "$ROOT/.processed"
    grep -Fxq -- "VIDD-------" "$ROOT/.processed"
}

@test "trusted cursor (in .processed): walk stops at cursor" {
    channels_with "@trustchan"
    set_channel trustchan NEW1------- NEW2------- OLD1------- OLD2-------
    mark_processed "OLD1-------"
    set_cursor trustchan OLD1-------

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "NEW1-------" "$ROOT/.processed"
    grep -Fxq -- "NEW2-------" "$ROOT/.processed"
    # OLD2------- sits below the cursor and must NOT be picked up.
    ! grep -Fxq -- "OLD2-------" "$ROOT/.processed"
}

@test "deferred cursor advance: cursor stays put when oldest discovery fails" {
    # Feed: NEW-------- (newest) → OLD-------- (oldest, just above cursor PREV-------).
    # NEW-------- lands but OLD-------- fails. New cursor should stay at PREV------- because
    # advancement requires contiguous-from-old-cursor landings.
    channels_with "@defchan"
    set_channel defchan NEW-------- OLD-------- PREV-------
    mark_processed "PREV-------"
    set_cursor defchan PREV-------
    export MOCK_CLAUDE_FAIL="OLD--------"

    run_ingest

    [ "$status" -eq 1 ]
    grep -Fxq -- "NEW--------" "$ROOT/.processed"
    ! grep -Fxq -- "OLD--------" "$ROOT/.processed"
    # Cursor unchanged: still PREV-------. OLD-------- will be retried next run.
    [ "$(cat "$ROOT/.channels/defchan")" = "PREV-------" ]
    [[ "$output" == *"cursor unchanged"* ]]
}

@test "deferred cursor advance: cursor moves to newest when all land" {
    channels_with "@allchan"
    set_channel allchan NEWEST----- MIDDLE----- OLDEST----- PREV-------
    mark_processed "PREV-------"
    set_cursor allchan PREV-------

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "NEWEST-----" "$ROOT/.processed"
    grep -Fxq -- "MIDDLE-----" "$ROOT/.processed"
    grep -Fxq -- "OLDEST-----" "$ROOT/.processed"
    [ "$(cat "$ROOT/.channels/allchan")" = "NEWEST-----" ]
    [[ "$output" == *"cursor → NEWEST-----"* ]]
}

@test "spend limit: run is cut short, remainder reported deferred" {
    set_playlist "SPEND1-----"
    export MOCK_CLAUDE_SPEND_LIMIT="SPEND1-----"

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"deferred (Claude spend limit"* ]]
    ! grep -Fxq -- "SPEND1-----" "$ROOT/.processed" 2>/dev/null
    # Marker is cleaned up by ingest.sh after detecting it.
    [ ! -f "$ROOT/.spend-limit" ]
}

@test "run watchdog: caps the fan-out and reports termination" {
    # A worker that outlives a tiny run cap forces the watchdog to fire.
    set_playlist "SLOW1------"
    export MOCK_CLAUDE_SLEEP=3
    export YOUTUBE_INGEST_RUN_TIMEOUT=1

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"run watchdog: fan-out exceeded 1s"* ]]
}

@test "build-index runs after a successful pass" {
    set_playlist "VID200-----"

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "VID200-----" "$ROOT/.processed"
    [ -f "$ROOT/youtube-knowledge-base.md" ]
    [[ "$output" == *"index refreshed"* ]]
}

@test "build-index does NOT run when nothing was ingested" {
    set_playlist "VID201-----"
    mark_processed "VID201-----"

    run_ingest

    [ "$status" -eq 0 ]
    [ ! -f "$ROOT/youtube-knowledge-base.md" ]
    [[ "$output" != *"index refreshed"* ]]
}

@test "bootstrap: latest already in .processed adopts cursor without ingesting" {
    channels_with "@bootchan"
    set_channel bootchan ALREADY----
    mark_processed "ALREADY----"

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"bootstrapped, cursor=ALREADY---- (already processed)"* ]]
    [ "$(cat "$ROOT/.channels/bootchan")" = "ALREADY----" ]
}

@test "bootstrap: latest not yet processed → cursor deferred until ingest lands" {
    channels_with "@newchan"
    set_channel newchan FRESH------

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "FRESH------" "$ROOT/.processed"
    [ "$(cat "$ROOT/.channels/newchan")" = "FRESH------" ]
}

@test "bootstrap: ingest fails → no cursor file written (next run re-bootstraps)" {
    channels_with "@failchan"
    set_channel failchan BROKEN-----
    export MOCK_CLAUDE_FAIL="BROKEN-----"

    run_ingest

    [ "$status" -eq 1 ]
    ! grep -Fxq -- "BROKEN-----" "$ROOT/.processed" 2>/dev/null
    [ ! -f "$ROOT/.channels/failchan" ]
}

@test "missing Claude CLI aborts before discovery or per-video writes" {
    set_playlist "CLAUDEMISS-"
    export YOUTUBE_INGEST_CLAUDE_BIN="$BATS_TEST_TMPDIR/missing-claude"

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"Claude CLI not found"* ]]
    [ ! -e "$ROOT/CLAUDEMISS-" ]
}

@test "ingest-one rejects a missing Claude CLI before creating a video directory" {
    export YOUTUBE_INGEST_CLAUDE_BIN="$BATS_TEST_TMPDIR/missing-claude"

    run_ingest_one "CLAUDEONE--"

    [ "$status" -eq 1 ]
    grep -Fq "Claude CLI not found" "$ROOT/.ingest.log"
    [ ! -e "$ROOT/CLAUDEONE--" ]
}

@test "--help prints usage and touches nothing" {
    run_ingest --help

    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: ingest.sh"* ]]
    [ ! -s "$ROOT/.processed" ]
}

@test "non-URL playlist argument is rejected (the --help-as-playlist incident)" {
    run_ingest --frobnicate

    [ "$status" -eq 2 ]
    [[ "$output" == *"playlist must be an http(s) URL"* ]]
}

@test "network gate: unreachable network gives up loudly instead of running blind" {
    export MOCK_CURL_FAIL=1
    export YOUTUBE_INGEST_NETWORK_WAIT=0
    set_playlist "VID300-----"

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"network still unreachable"* ]]
    ! grep -Fxq -- "VID300-----" "$ROOT/.processed" 2>/dev/null
}

@test "network gate: run proceeds once connectivity returns" {
    export MOCK_CURL_FAIL_COUNT=2
    export YOUTUBE_INGEST_NETWORK_POLL=1
    set_playlist "VID301-----"

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"network up after"* ]]
    grep -Fxq -- "VID301-----" "$ROOT/.processed"
}

@test "playlist enumeration failure is loud — never mistaken for an empty playlist" {
    export MOCK_YT_DLP_PLAYLIST_FAIL=1

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"playlist enumeration FAILED"* ]]
    [[ "$output" == *"discovery source(s) FAILED; results incomplete"* ]]
}

@test "channel bootstrap fetch failure skips the channel, not the run" {
    # Regression: a channel with no cursor whose feed fetch fails used to
    # abort the whole script (bare command-substitution assignment under
    # set -e) — killing every scheduled run the morning after a new channel
    # was added while the network was down.
    channels_with "@deadchan" "@livechan"
    export MOCK_YT_DLP_CHANNEL_FAIL="deadchan"
    set_channel livechan LIVE1------

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"channel @deadchan: feed fetch FAILED"* ]]
    grep -Fxq -- "LIVE1------" "$ROOT/.processed"
    [ ! -f "$ROOT/.channels/deadchan" ]
}

@test "channel steady-state fetch failure is loud, not 'nothing new'" {
    channels_with "@flakychan"
    mark_processed "PREV-------"
    set_cursor flakychan PREV-------
    export MOCK_YT_DLP_CHANNEL_FAIL="flakychan"

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"channel @flakychan: feed fetch FAILED"* ]]
    [[ "$output" != *"channel @flakychan: nothing new"* ]]
    [ "$(cat "$ROOT/.channels/flakychan")" = "PREV-------" ]
}

@test "junk ids from a corrupted source are dropped; real ones still ingest" {
    # "Options:"/"[OPTIONS]" fail the charset; "yt-dlp" is charset-valid but
    # not 11 chars — both classes of junk must be dropped before fan-out.
    set_playlist "GOOD1------ Options: [OPTIONS] yt-dlp"

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"dropping junk id from queue: Options:"* ]]
    [[ "$output" == *"dropping junk id from queue: [OPTIONS]"* ]]
    [[ "$output" == *"dropping junk id from queue: yt-dlp"* ]]
    grep -Fxq -- "GOOD1------" "$ROOT/.processed"
    [ ! -d "$ROOT/Options:" ]
}

@test "ingest-one rejects a malformed video id before touching the filesystem" {
    run_ingest_one "../escape"

    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid video id"* ]]
    [ ! -e "$ROOT/../escape" ]
}

@test "truncated channel feed: discoveries ingest, cursor pins, next run recovers the rest" {
    # Feed (newest-first): TRNEW1, TRNEW2, PREV(=cursor). The feed dies after
    # emitting TRNEW1, so TRNEW2 sits unseen between cursor and truncation
    # point — advancing the cursor to TRNEW1 would skip it forever.
    channels_with "@truncchan"
    set_channel truncchan TRNEW1----- TRNEW2----- PREV-------
    mark_processed "PREV-------"
    set_cursor truncchan "PREV-------"
    export MOCK_YT_DLP_CHANNEL_TRUNCATE="truncchan:1"

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"feed walk TRUNCATED"* ]]
    grep -Fxq -- "TRNEW1-----" "$ROOT/.processed"
    ! grep -Fxq -- "TRNEW2-----" "$ROOT/.processed"
    [ "$(cat "$ROOT/.channels/truncchan")" = "PREV-------" ]
    [[ "$output" == *"cursor unchanged (feed walk truncated"* ]]

    # A healthy walk next run rediscovers the unseen video and only then
    # advances the cursor.
    unset MOCK_YT_DLP_CHANNEL_TRUNCATE
    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "TRNEW2-----" "$ROOT/.processed"
    [ "$(cat "$ROOT/.channels/truncchan")" = "TRNEW2-----" ]
}
