#!/usr/bin/env bats
# Tests for ingest-one.sh failure-cleanup behaviour.

load lib

@test "ingest-one: happy path writes synopsis and records ID" {
    run_ingest_one VID001-----

    [ "$status" -eq 0 ]
    [ -f "$ROOT/VID001-----/.transcript/transcript.json" ]
    [ -f "$ROOT/VID001-----/meta.json" ]
    [ -f "$ROOT/VID001-----/mock-synopsis-VID001-----.md" ]
    grep -Fxq -- "VID001-----" "$ROOT/.processed"
}

@test "ingest-one: spend-limit refusal exits 255, keeps download, drops marker" {
    MOCK_CLAUDE_SPEND_LIMIT="VID006-----" run_ingest_one VID006-----

    [ "$status" -eq 255 ]
    [ -f "$ROOT/.spend-limit" ]
    [ -s "$ROOT/VID006-----/.transcript/transcript.json" ]
    [ -s "$ROOT/VID006-----/meta.json" ]
    ! grep -Fxq -- "VID006-----" "$ROOT/.processed" 2>/dev/null
}

@test "ingest-one: generic ytt failure removes the dir, does not ledger" {
    MOCK_YTT_FAIL="VID002-----" run_ingest_one VID002-----

    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/VID002-----" ]
    ! grep -Fxq -- "VID002-----" "$ROOT/.processed" 2>/dev/null
    ! grep -Fxq -- "VID002-----" "$ROOT/.download-failed" 2>/dev/null
}

@test "ingest-one: no-transcript is recorded as undownloadable" {
    MOCK_YTT_NO_TRANSCRIPT="VIDNT0-----" run_ingest_one VIDNT0-----

    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/VIDNT0-----" ]
    grep -Fxq -- "VIDNT0-----" "$ROOT/.download-failed"
}

@test "ingest-one: No-such-file race does not ledger" {
    MOCK_YTT_NO_SUCH_FILE="VIDIO0-----" run_ingest_one VIDIO0-----

    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/VIDIO0-----" ]
    ! grep -Fxq -- "VIDIO0-----" "$ROOT/.download-failed" 2>/dev/null
}

@test "ingest-one: meta-fetch failure (pipefail) removes the dir, does not ledger" {
    MOCK_YT_DLP_META_FAIL="VID003-----" run_ingest_one VID003-----

    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/VID003-----" ]
    ! grep -Fxq -- "VID003-----" "$ROOT/.processed" 2>/dev/null
    ! grep -Fxq -- "VID003-----" "$ROOT/.download-failed" 2>/dev/null
}

@test "ingest-one: synopsis failure keeps the download" {
    MOCK_CLAUDE_FAIL="VID004-----" run_ingest_one VID004-----

    [ "$status" -ne 0 ]
    [ -s "$ROOT/VID004-----/.transcript/transcript.json" ]
    [ -s "$ROOT/VID004-----/meta.json" ]
    ! grep -Fxq -- "VID004-----" "$ROOT/.processed" 2>/dev/null
}

@test "ingest-one: synopsis exits 0 but writes nothing — download kept" {
    MOCK_CLAUDE_NO_WRITE="VID005-----" run_ingest_one VID005-----

    [ "$status" -ne 0 ]
    [ -s "$ROOT/VID005-----/.transcript/transcript.json" ]
    [ -s "$ROOT/VID005-----/meta.json" ]
    ! grep -Fxq -- "VID005-----" "$ROOT/.processed" 2>/dev/null
}

@test "ingest-one --download accepts an id that starts with a dash" {
    run_ingest_one --download -- -Gj0-EIyx6g

    [ "$status" -eq 0 ]
    [ -s "$ROOT/-Gj0-EIyx6g/.transcript/transcript.json" ]
    [ -s "$ROOT/-Gj0-EIyx6g/meta.json" ]
}

# Live 2026-08-22: xargs invoked ingest-one --download -Gj0-EIyx6g (no --),
# and the case arm treated the ID as an unknown flag. The -- test above
# does not cover that path.
@test "ingest-one --download accepts a dash-prefix id without --" {
    run_ingest_one --download -Gj0-EIyx6g

    [ "$status" -eq 0 ]
    [[ "$output" != *"unknown flag"* ]]
    [ -s "$ROOT/-Gj0-EIyx6g/.transcript/transcript.json" ]
    [ -s "$ROOT/-Gj0-EIyx6g/meta.json" ]
}

@test "ingest-one --download writes transcript and meta, not synopsis" {
    run_ingest_one --download VID007-----

    [ "$status" -eq 0 ]
    [ -s "$ROOT/VID007-----/.transcript/transcript.json" ]
    [ -s "$ROOT/VID007-----/meta.json" ]
    [ ! -f "$ROOT/VID007-----/mock-synopsis-VID007-----.md" ]
    ! grep -Fxq -- "VID007-----" "$ROOT/.processed" 2>/dev/null
}

@test "ingest-one --analyze synopses an already-downloaded video" {
    run_ingest_one --download VID008-----
    [ "$status" -eq 0 ]

    run_ingest_one --analyze VID008-----

    [ "$status" -eq 0 ]
    [ -f "$ROOT/VID008-----/mock-synopsis-VID008-----.md" ]
    grep -Fxq -- "VID008-----" "$ROOT/.processed"
}

@test "ingest-one --analyze without a download fails and creates no dir" {
    run_ingest_one --analyze VID009-----

    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/VID009-----" ]
    ! grep -Fxq -- "VID009-----" "$ROOT/.processed" 2>/dev/null
}
