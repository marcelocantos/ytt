#!/usr/bin/env bats
# Tests for ingest-one.sh failure-cleanup behaviour.

load lib

@test "ingest-one: happy path writes synopsis and records ID" {
    run_ingest_one VID001

    [ "$status" -eq 0 ]
    [ -f "$ROOT/VID001/.transcript/transcript.md" ]
    [ -f "$ROOT/VID001/meta.json" ]
    [ -f "$ROOT/VID001/mock-synopsis-VID001.md" ]
    grep -Fxq -- "VID001" "$ROOT/.processed"
}

@test "ingest-one: ytt failure removes the dir entirely" {
    MOCK_YTT_FAIL="VID002" run_ingest_one VID002

    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/VID002" ]
    ! grep -Fxq -- "VID002" "$ROOT/.processed" 2>/dev/null
}

@test "ingest-one: meta-fetch failure (pipefail) removes the dir" {
    MOCK_YT_DLP_META_FAIL="VID003" run_ingest_one VID003

    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/VID003" ]
    ! grep -Fxq -- "VID003" "$ROOT/.processed" 2>/dev/null
}

@test "ingest-one: claude synopsis failure removes the dir" {
    MOCK_CLAUDE_FAIL="VID004" run_ingest_one VID004

    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/VID004" ]
    ! grep -Fxq -- "VID004" "$ROOT/.processed" 2>/dev/null
}

@test "ingest-one: claude exits 0 but writes nothing — dir still removed" {
    MOCK_CLAUDE_NO_WRITE="VID005" run_ingest_one VID005

    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/VID005" ]
    ! grep -Fxq -- "VID005" "$ROOT/.processed" 2>/dev/null
}
