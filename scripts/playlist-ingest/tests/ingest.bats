#!/usr/bin/env bats
# Tests for ingest.sh: orphan sweep, stale-cursor recovery, deferred
# cursor advance, and KB index regeneration.

load lib

@test "orphan sweep: stale dir without .processed entry is reclaimed and re-ingested" {
    # Arrange: pre-create an orphan dir for VID100 with junk content.
    mkdir -p "$ROOT/VID100/.transcript"
    : > "$ROOT/VID100/meta.json"
    set_playlist "VID100"

    # Act
    run_ingest

    # Assert: orphan log fired, video re-ingested cleanly.
    [ "$status" -eq 0 ]
    [[ "$output" == *"orphan dirs from failed prior runs (queued for retry): VID100"* ]]
    grep -Fxq -- "VID100" "$ROOT/.processed"
    [ -f "$ROOT/VID100/mock-synopsis-VID100.md" ]
}

@test "orphan sweep: dir already in .processed is left alone" {
    mkdir -p "$ROOT/VID101"
    : > "$ROOT/VID101/mock-synopsis-VID101.md"
    mark_processed "VID101"
    set_playlist ""

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" != *"orphan dirs from failed prior runs"* ]]
    [ -d "$ROOT/VID101" ]
}

@test "stale cursor (not in .processed): walk proceeds past it; videos recovered" {
    channels_with "@stalechan"
    set_channel stalechan VIDA VIDB VIDC VIDD
    # Cursor points at VIDB but VIDB isn't in .processed — speculative leftover.
    set_cursor stalechan VIDB

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"cursor VIDB not in .processed; treating as stale"* ]]
    # All four feed entries should be queued (none in .processed yet).
    grep -Fxq -- "VIDA" "$ROOT/.processed"
    grep -Fxq -- "VIDB" "$ROOT/.processed"
    grep -Fxq -- "VIDC" "$ROOT/.processed"
    grep -Fxq -- "VIDD" "$ROOT/.processed"
}

@test "trusted cursor (in .processed): walk stops at cursor" {
    channels_with "@trustchan"
    set_channel trustchan NEW1 NEW2 OLD1 OLD2
    mark_processed "OLD1"
    set_cursor trustchan OLD1

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "NEW1" "$ROOT/.processed"
    grep -Fxq -- "NEW2" "$ROOT/.processed"
    # OLD2 sits below the cursor and must NOT be picked up.
    ! grep -Fxq -- "OLD2" "$ROOT/.processed"
}

@test "deferred cursor advance: cursor stays put when oldest discovery fails" {
    # Feed: NEW (newest) → OLD (oldest, just above cursor PREV).
    # NEW lands but OLD fails. New cursor should stay at PREV because
    # advancement requires contiguous-from-old-cursor landings.
    channels_with "@defchan"
    set_channel defchan NEW OLD PREV
    mark_processed "PREV"
    set_cursor defchan PREV
    export MOCK_CLAUDE_FAIL="OLD"

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "NEW" "$ROOT/.processed"
    ! grep -Fxq -- "OLD" "$ROOT/.processed"
    # Cursor unchanged: still PREV. OLD will be retried next run.
    [ "$(cat "$ROOT/.channels/defchan")" = "PREV" ]
    [[ "$output" == *"cursor unchanged"* ]]
}

@test "deferred cursor advance: cursor moves to newest when all land" {
    channels_with "@allchan"
    set_channel allchan NEWEST MIDDLE OLDEST PREV
    mark_processed "PREV"
    set_cursor allchan PREV

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "NEWEST" "$ROOT/.processed"
    grep -Fxq -- "MIDDLE" "$ROOT/.processed"
    grep -Fxq -- "OLDEST" "$ROOT/.processed"
    [ "$(cat "$ROOT/.channels/allchan")" = "NEWEST" ]
    [[ "$output" == *"cursor → NEWEST"* ]]
}

@test "build-index runs after a successful pass" {
    set_playlist "VID200"

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "VID200" "$ROOT/.processed"
    [ -f "$ROOT/youtube-knowledge-base.md" ]
    [[ "$output" == *"index refreshed"* ]]
}

@test "build-index does NOT run when nothing was ingested" {
    set_playlist "VID201"
    mark_processed "VID201"

    run_ingest

    [ "$status" -eq 0 ]
    [ ! -f "$ROOT/youtube-knowledge-base.md" ]
    [[ "$output" != *"index refreshed"* ]]
}

@test "bootstrap: latest already in .processed adopts cursor without ingesting" {
    channels_with "@bootchan"
    set_channel bootchan ALREADY
    mark_processed "ALREADY"

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"bootstrapped, cursor=ALREADY (already processed)"* ]]
    [ "$(cat "$ROOT/.channels/bootchan")" = "ALREADY" ]
}

@test "bootstrap: latest not yet processed → cursor deferred until ingest lands" {
    channels_with "@newchan"
    set_channel newchan FRESH

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "FRESH" "$ROOT/.processed"
    [ "$(cat "$ROOT/.channels/newchan")" = "FRESH" ]
}

@test "bootstrap: ingest fails → no cursor file written (next run re-bootstraps)" {
    channels_with "@failchan"
    set_channel failchan BROKEN
    export MOCK_CLAUDE_FAIL="BROKEN"

    run_ingest

    [ "$status" -eq 0 ]
    ! grep -Fxq -- "BROKEN" "$ROOT/.processed" 2>/dev/null
    [ ! -f "$ROOT/.channels/failchan" ]
}
