#!/usr/bin/env bats

load lib

@test "broker preflight aborts before dispatching the synopsis backlog" {
    run_ingest_one --download VID900-----
    [ "$status" -eq 0 ]
    export MOCK_SYNOPSIS_PREFLIGHT_FAIL=1
    run_ingest --analyze
    [ "$status" -eq 1 ]
    [[ "$output" == *"backlog not dispatched"* ]]
    ! grep -q 'analyze start' "$ROOT/.ingest.log"
    [[ "$(reported)" == *"send problem"* ]]
}

@test "capacity preflight quietly defers even with a stale liveness stamp" {
    set_last_ingest_days_ago 15
    export MOCK_SYNOPSIS_PREFLIGHT_CAPACITY=1
    run_ingest --analyze
    [ "$status" -eq 0 ]
    [[ "$output" == *"analysis deferred"* ]]
    [ -z "$(reported)" ]
}

@test "a broker lost after preflight stops the analyze batch" {
    for id in VID905----- VID906----- VID907-----; do
        run_ingest_one --download "$id"
        [ "$status" -eq 0 ]
    done
    export YOUTUBE_INGEST_ANALYZE_CONCURRENCY=1
    export MOCK_SYNOPSIS_BACKEND_FAIL=1
    run_ingest --analyze
    [ "$status" -eq 1 ]
    [ "$(grep -c 'analyze start' "$ROOT/.ingest.log")" -eq 1 ]
    [ "$(grep -c '^send problem' "$BLURTER_LOG")" -eq 1 ]
    [ ! -f "$ROOT/.spend-limit" ]
}

@test "YouTube 429 stops the batch and subsequent download ticks quietly defer" {
    set_playlist VID901----- VID902----- VID903-----
    export YOUTUBE_INGEST_CONCURRENCY=1
    export MOCK_YTT_RATE_LIMIT=VID901-----,VID902-----,VID903-----
    run_ingest --download
    [ "$status" -eq 0 ]
    [[ "$output" == *"downloads deferred after YouTube throttling"* ]]
    [ -z "$(reported)" ]
    [ "$(grep -c 'download start' "$ROOT/.ingest.log")" -eq 1 ]
    # No discovery, fetch, unhealthy event, or false recovery on the next tick.
    export MOCK_YT_DLP_PLAYLIST_FAIL=1
    set_last_ingest_days_ago 15
    run_ingest --download
    [ "$status" -eq 0 ]
    [[ "$output" == *"YouTube download deferred until"* ]]
    [[ "$output" != *"playlist="* ]]
    [ -z "$(reported)" ]
    [ "$(grep -c 'download start' "$ROOT/.ingest.log")" -eq 1 ]
}

@test "download cooldown still allows already-downloaded videos to be analyzed" {
    run_ingest_one --download VID904-----
    [ "$status" -eq 0 ]
    run bash -c 'printf "HTTP Error 429" | "$YTT_GO_BIN" ingest-control download-failure'
    [ "$status" -eq 75 ]
    export MOCK_YT_DLP_PLAYLIST_FAIL=1
    run_ingest
    [ "$status" -eq 0 ]
    grep -Fxq VID904----- "$ROOT/.processed"
    [ -z "$(reported)" ]
}

@test "problem and recovery reports use the same stage key" {
    export MOCK_SYNOPSIS_PREFLIGHT_FAIL=1
    run_ingest --analyze
    [ "$status" -eq 1 ]
    unset MOCK_SYNOPSIS_PREFLIGHT_FAIL
    run_ingest --analyze
    [ "$status" -eq 0 ]
    [ "$(grep -c 'ytt-ingest-analyze-problem$' "$BLURTER_LOG")" -eq 2 ]
}
