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

@test "orphan sweep: dry run reports the orphan but does not delete its dir" {
    mkdir -p "$ROOT/VID102-----/.transcript"
    : > "$ROOT/VID102-----/meta.json"
    set_playlist "VID102-----"

    run_ingest --dry-run

    [[ "$output" == *"orphan dirs from failed prior runs (queued for retry): VID102-----"* ]]
    [ -f "$ROOT/VID102-----/meta.json" ]
    # Not ingested and not marked processed — a dry run only reports.
    [ ! -f "$ROOT/VID102-----/mock-synopsis-VID102-----.md" ]
    ! grep -Fxq -- "VID102-----" "$ROOT/.processed"
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
    [[ "$output" == *"deferred (synopsis providers at capacity"* ]]
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
    [[ "$output" == *"run watchdog: analyze fan-out exceeded 1s"* ]]
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

@test "ytt without build-index aborts before discovery" {
    set_playlist "NOINDEX----"
    old_ytt="$BATS_TEST_TMPDIR/old-ytt"
    cat > "$old_ytt" <<'EOF'
#!/usr/bin/env bash
# Stand-in for Homebrew 0.11.0: argparse help, no build-index subcommand.
echo "usage: ytt [-h] [-t | --json] [VIDEO ...]"
exit 0
EOF
    chmod +x "$old_ytt"
    export YOUTUBE_INGEST_YTT_BIN="$old_ytt"

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"does not implement build-index"* ]]
    [ ! -e "$ROOT/NOINDEX----" ]
}

@test "ytt without synopsis aborts before discovery" {
    set_playlist "NOSYN------"
    old_ytt="$BATS_TEST_TMPDIR/old-ytt"
    cat > "$old_ytt" <<'EOF'
#!/usr/bin/env bash
echo "ytt build-index    regenerate the knowledge-base index"
exit 0
EOF
    chmod +x "$old_ytt"
    export YOUTUBE_INGEST_YTT_BIN="$old_ytt"

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"does not implement synopsis"* ]]
    [ ! -e "$ROOT/NOSYN------" ]
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

# --- the 2026-07-10 regression: config orphaned by pinning the install ------

@test "orphaned channels config (cursors exist, config gone) is loud, not a cheerful no-op" {
    # Reproduces the 15-day outage: the scheduler was pinned to the Homebrew
    # binary, so config resolution pointed into the Cellar where the gitignored
    # channels.yaml has never existed. Cursors prove channels WERE working.
    no_channels_config
    set_cursor natebjones "PREV-------"
    mark_processed "PREV-------"
    set_playlist ""

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"channels config MISSING"* ]]
    [[ "$output" == *"the config was orphaned, not disabled"* ]]
    [[ "$output" == *"natebjones"* ]]
    [[ "$(reported)" == *"send problem ytt ingest unhealthy"* ]]
    [[ "$(reported)" == *"channels config MISSING"* ]]
}

@test "no channels config and no cursors is a legitimate playlist-only setup (silent, exit 0)" {
    # The same missing file must NOT alert when channel ingest was simply never
    # enabled — otherwise every playlist-only user is permanently 'unhealthy'.
    no_channels_config
    set_playlist ""

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping channel ingest"* ]]
    [[ "$output" != *"config was orphaned"* ]]
    [[ "$(reported)" != *problem* ]]
}

@test "channels config resolves from XDG config dir, not the install directory" {
    use_xdg_channels_config "@xdgchan"
    set_channel xdgchan XDGVID1----
    set_playlist ""

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"channel @xdgchan"* ]]
    grep -Fxq -- "XDGVID1----" "$ROOT/.processed"
}

@test "explicit YOUTUBE_CHANNELS_FILE still wins over the XDG config dir" {
    use_xdg_channels_config "@xdgchan"
    export YOUTUBE_CHANNELS_FILE="$BATS_TEST_TMPDIR/explicit.yaml"
    printf 'channels:\n  - handle: "@explicitchan"\n' > "$YOUTUBE_CHANNELS_FILE"
    set_channel explicitchan EXPVID1----
    set_channel xdgchan XDGVID1----
    set_playlist ""

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "EXPVID1----" "$ROOT/.processed"
    ! grep -Fxq -- "XDGVID1----" "$ROOT/.processed"
}

@test "extra-id queue: pending IDs are ingested through the paced workers" {
    set_playlist ""
    export YOUTUBE_INGEST_QUEUE="$BATS_TEST_TMPDIR/backfill.ids"
    printf '%s\n' "QID100-----" "# comment" "QID101-----" "" > "$YOUTUBE_INGEST_QUEUE"

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"queue=$YOUTUBE_INGEST_QUEUE pending=2"* ]]
    grep -Fxq -- "QID100-----" "$ROOT/.processed"
    grep -Fxq -- "QID101-----" "$ROOT/.processed"
}

@test "extra-id queue: already-processed IDs are skipped" {
    set_playlist ""
    mark_processed "QID200-----"
    export YOUTUBE_INGEST_QUEUE="$BATS_TEST_TMPDIR/backfill.ids"
    printf '%s\n' "QID200-----" "QID201-----" > "$YOUTUBE_INGEST_QUEUE"

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"pending=1"* ]]
    grep -Fxq -- "QID201-----" "$ROOT/.processed"
}

@test "extra-id queue: junk lines are dropped rather than dispatched" {
    set_playlist ""
    export YOUTUBE_INGEST_QUEUE="$BATS_TEST_TMPDIR/backfill.ids"
    printf '%s\n' "not-an-id" "QID300-----" "Options:" > "$YOUTUBE_INGEST_QUEUE"

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"dropping junk id from queue: not-an-id"* ]]
    [[ "$output" == *"dropping junk id from queue: Options:"* ]]
    grep -Fxq -- "QID300-----" "$ROOT/.processed"
}

@test "UC-id channel handle walks /channel/UC…/videos" {
    channels_with "UCabcdefghijklmnopqrstuv"
    set_channel UCabcdefghijklmnopqrstuv UCVID1-----
    set_playlist ""

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "UCVID1-----" "$ROOT/.processed"
    [ -f "$ROOT/.channels/UCabcdefghijklmnopqrstuv" ]
}

# --- staleness backstop: success that produces nothing, forever -------------

@test "staleness: tracked channels producing nothing for too long is unhealthy" {
    channels_with "@quietchan"
    set_channel quietchan "OLD--------"
    mark_processed "OLD--------"
    set_cursor quietchan "OLD--------"
    set_playlist ""
    set_last_ingest_days_ago 15

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$output" == *"nothing ingested for 15 days"* ]]
    [[ "$output" == *"reporting success while producing nothing"* ]]
    [[ "$(reported)" == *"send problem ytt ingest unhealthy"* ]]
}

@test "staleness: quiet playlist-only setup never trips the check" {
    # No channels file ⇒ going quiet is the expected steady state.
    no_channels_config
    set_playlist ""
    set_last_ingest_days_ago 90

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" != *"nothing ingested for"* ]]
    [[ "$(reported)" != *problem* ]]
}

@test "staleness: threshold is configurable and 0 disables it" {
    channels_with "@quietchan"
    set_channel quietchan "OLD--------"
    mark_processed "OLD--------"
    set_cursor quietchan "OLD--------"
    set_playlist ""
    set_last_ingest_days_ago 30

    YOUTUBE_INGEST_STALE_DAYS=0 run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" != *"nothing ingested for"* ]]
}

@test "staleness: a landed video refreshes the liveness stamp" {
    channels_with "@livechan"
    set_channel livechan "LIVE1------"
    set_last_ingest_days_ago 30

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "LIVE1------" "$ROOT/.processed"
    # Stamp must now be ~now, so the next run doesn't inherit the stale verdict.
    stamp="$(cat "$YOUTUBE_INGEST_STATE_DIR/last-ingest")"
    (( $(date -u +%s) - stamp < 300 ))
}

# --- alert coverage ---------------------------------------------------------

@test "a healthy run alerts nobody" {
    set_playlist "HEALTHY1---"

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$(reported)" == *"send ok ytt ingest healthy"* ]]
    [[ "$(reported)" != *problem* ]]
}

@test "per-video ingest failures are alerted, not just logged" {
    set_playlist "FAILVID1---"
    export MOCK_CLAUDE_FAIL="FAILVID1---"

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$(reported)" == *"send problem ytt ingest unhealthy"* ]]
    [[ "$(reported)" == *"analyze(s) failed this tick and stay on disk"* ]]
}

@test "a ytt missing synopsis alerts before discovery" {
    old_ytt="$BATS_TEST_TMPDIR/old-ytt"
    cat > "$old_ytt" <<'EOF'
#!/usr/bin/env bash
echo "ytt build-index    regenerate the knowledge-base index"
exit 0
EOF
    chmod +x "$old_ytt"
    export YOUTUBE_INGEST_YTT_BIN="$old_ytt"
    set_playlist "VID300-----"

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$(reported)" == *"send problem ytt ingest aborted before discovery"* ]]
    [[ "$(reported)" == *"does not implement synopsis"* ]]
}

@test "network give-up alerts instead of dying into the log" {
    export MOCK_CURL_FAIL=1
    export YOUTUBE_INGEST_NETWORK_WAIT=1
    export YOUTUBE_INGEST_NETWORK_POLL=1

    run_ingest

    [ "$status" -eq 1 ]
    [[ "$(reported)" == *"send problem ytt ingest aborted before discovery"* ]]
    [[ "$(reported)" == *"network still unreachable"* ]]
}

# --- dry run ---------------------------------------------------------------

@test "--dry-run reports the queue without ingesting or alerting" {
    channels_with "@drychan"
    set_channel drychan DRY1------- DRY2-------
    set_playlist "DRYPL1-----"

    run_ingest --dry-run

    [ "$status" -eq 0 ]
    # Bootstrap takes only the channel's latest upload, so: 1 playlist + 1 channel.
    [[ "$output" == *"dry run: 2 video(s) would be downloaded"* ]]
    [[ "$output" == *"DRY1-------"* ]]
    # Nothing ingested, nothing recorded, nobody paged.
    [ ! -s "$ROOT/.processed" ]
    [ ! -d "$ROOT/DRY1-------" ]
    [ -z "$(reported)" ]
}

@test "orphan sweep: complete download waiting for analysis is kept" {
    mkdir -p "$ROOT/PENDID-----/.transcript"
    printf '{"video_id":"PENDID-----"}\n' > "$ROOT/PENDID-----/.transcript/transcript.json"
    printf '{"title":"pending","id":"PENDID-----"}\n' > "$ROOT/PENDID-----/meta.json"
    set_playlist ""

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" != *"orphan dirs from failed prior runs"* ]]
    grep -Fxq -- "PENDID-----" "$ROOT/.processed"
    [ -f "$ROOT/PENDID-----/mock-synopsis-PENDID-----.md" ]
}

@test "--download fetches without analyzing" {
    set_playlist "DLONLY-----"

    run_ingest --download

    [ "$status" -eq 0 ]
    [ -s "$ROOT/DLONLY-----/.transcript/transcript.json" ]
    [ -s "$ROOT/DLONLY-----/meta.json" ]
    [ ! -f "$ROOT/DLONLY-----/mock-synopsis-DLONLY-----.md" ]
    ! grep -Fxq -- "DLONLY-----" "$ROOT/.processed" 2>/dev/null
}

@test "--analyze synopses on-disk downloads and skips YouTube discovery" {
    mkdir -p "$ROOT/ANONLY-----/.transcript"
    printf '{"video_id":"ANONLY-----"}\n' > "$ROOT/ANONLY-----/.transcript/transcript.json"
    printf '{"title":"on disk","id":"ANONLY-----"}\n' > "$ROOT/ANONLY-----/meta.json"
    set_playlist "SHOULDNT---"

    run_ingest --analyze

    [ "$status" -eq 0 ]
    grep -Fxq -- "ANONLY-----" "$ROOT/.processed"
    [ -f "$ROOT/ANONLY-----/mock-synopsis-ANONLY-----.md" ]
    [ ! -d "$ROOT/SHOULDNT---" ]
}

@test "undownloadable ids are recorded once and not retried" {
    set_playlist "FAILID----- GOODID-----"
    export MOCK_YTT_NO_TRANSCRIPT="FAILID-----"
    export YOUTUBE_INGEST_DOWNLOAD_BATCH=16

    run_ingest --download
    [ "$status" -eq 0 ]
    grep -Fxq -- "FAILID-----" "$ROOT/.download-failed"
    [ -s "$ROOT/GOODID-----/.transcript/transcript.json" ]
    [[ "$output" != *"UNHEALTHY"* ]]

    run_ingest --download
    [ "$status" -eq 0 ]
    [[ "$output" != *"[FAILID-----] download start"* ]]
    [[ "$output" != *"UNHEALTHY"* ]]
}

@test "transient ytt failures are not recorded and are retried next tick" {
    set_playlist "FAILID----- GOODID-----"
    export MOCK_YTT_FAIL="FAILID-----"
    export YOUTUBE_INGEST_DOWNLOAD_BATCH=16

    run_ingest --download
    [ "$status" -eq 0 ]
    ! grep -Fxq -- "FAILID-----" "$ROOT/.download-failed" 2>/dev/null
    [ -s "$ROOT/GOODID-----/.transcript/transcript.json" ]
    [[ "$output" != *"UNHEALTHY"* ]]
    [[ "$output" == *"video trouble, not pipeline unhealthy"* ]]
    [[ "$(reported)" == *"send ok ytt ingest healthy"* ]]
    [[ "$(reported)" != *problem* ]]

    # A retry tick that only contains the sticky ID has no successful
    # neighbour — that is the lone-miss case. Keep a new success in the
    # batch so this still asserts "video trouble, pipeline fine".
    set_playlist "FAILID----- GOODID----- NEXTGOOD---"
    run_ingest --download
    [ "$status" -eq 0 ]
    [[ "$output" != *"UNHEALTHY"* ]]
    [[ "$output" == *"video trouble, not pipeline unhealthy"* ]]
    [ -s "$ROOT/NEXTGOOD---/.transcript/transcript.json" ]
    ! grep -Fxq -- "FAILID-----" "$ROOT/.download-failed" 2>/dev/null
    # Worker lines go to $ROOT/.ingest.log, not ingest.sh stdout.
    [ "$(grep -c '\[FAILID-----\] download start' "$ROOT/.ingest.log")" -ge 2 ]
}

@test "a lone download miss with no successful neighbour is pipeline unhealthy" {
    set_playlist "ONLYFAIL---"
    export MOCK_YTT_FAIL="ONLYFAIL---"

    run_ingest --download
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNHEALTHY"* ]]
    [[ "$output" == *"failed this tick and stay pending"* ]]
    [[ "$(reported)" == *"send problem ytt ingest unhealthy"* ]]
}

@test "download misses that outnumber successes are pipeline unhealthy" {
    set_playlist "FAIL1------ FAIL2------ GOODID-----"
    export MOCK_YTT_FAIL="FAIL1------,FAIL2------"

    run_ingest --download
    [ "$status" -ne 0 ]
    [ -s "$ROOT/GOODID-----/.transcript/transcript.json" ]
    [[ "$output" == *"UNHEALTHY"* ]]
    [[ "$output" == *"2 of 3 download(s) failed this tick and stay pending"* ]]
    [[ "$(reported)" == *"send problem ytt ingest unhealthy"* ]]
}

@test "playlist members-only ids are skipped at discovery, not downloaded" {
    set_playlist "PUB1------- MEM1------- PUB2-------"
    export MOCK_YT_DLP_MEMBERS_ONLY="MEM1-------"

    run_ingest

    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping subscriber_only MEM1------- at discovery"* ]]
    grep -Fxq -- "MEM1-------" "$ROOT/.download-failed"
    grep -Fxq -- "PUB1-------" "$ROOT/.processed"
    grep -Fxq -- "PUB2-------" "$ROOT/.processed"
    ! grep -Fxq -- "MEM1-------" "$ROOT/.processed"
    [ ! -d "$ROOT/MEM1-------" ]
    [[ "$output" != *"UNHEALTHY"* ]]
    [[ "$output" != *"[MEM1-------] download start"* ]]
}

@test "channel feed members-only ids are skipped; cursor still advances over public" {
    channels_with "@memchan"
    set_channel memchan NEW1------- MEM2------- CURSOR-----
    mark_processed "CURSOR-----"
    set_cursor memchan "CURSOR-----"
    export MOCK_YT_DLP_MEMBERS_ONLY="MEM2-------"

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "MEM2-------" "$ROOT/.download-failed"
    grep -Fxq -- "NEW1-------" "$ROOT/.processed"
    ! grep -Fxq -- "MEM2-------" "$ROOT/.processed"
    [ ! -d "$ROOT/MEM2-------" ]
    [ "$(cat "$ROOT/.channels/memchan")" = "NEW1-------" ]
    [[ "$output" != *"[MEM2-------] download start"* ]]
    [[ "$output" != *"UNHEALTHY"* ]]
}

@test "channel bootstrap whose latest upload is members-only starts at the newest public" {
    channels_with "@newmem"
    set_channel newmem MEM2------- BOOT1------
    export MOCK_YT_DLP_MEMBERS_ONLY="MEM2-------"

    run_ingest

    [ "$status" -eq 0 ]
    grep -Fxq -- "MEM2-------" "$ROOT/.download-failed"
    grep -Fxq -- "BOOT1------" "$ROOT/.processed"
    [ "$(cat "$ROOT/.channels/newmem")" = "BOOT1------" ]
    [[ "$output" != *"[MEM2-------] download start"* ]]
}

@test "--analyze does not wipe a fresh incomplete download dir" {
    mkdir -p "$ROOT/INFLIT-----/.transcript"
    : > "$ROOT/INFLIT-----/.transcript/transcript.raw.json"
    set_playlist ""

    run_ingest --analyze

    [ -d "$ROOT/INFLIT-----" ]
    [ -f "$ROOT/INFLIT-----/.transcript/transcript.raw.json" ]
}

@test "download tick fetches an id that starts with a dash" {
    set_playlist "-Gj0-EIyx6g"

    run_ingest --download

    [ "$status" -eq 0 ]
    [ -s "$ROOT/-Gj0-EIyx6g/.transcript/transcript.json" ]
    [[ "$output" != *"unknown flag"* ]]
    [[ "$output" != *"UNHEALTHY"* ]]
}

@test "download batch remainder is not reported as a failure" {
    set_playlist "BAT1------- BAT2------- BAT3-------"
    export YOUTUBE_INGEST_DOWNLOAD_BATCH=1

    run_ingest --download

    [ "$status" -eq 0 ]
    [[ "$output" == *"download batch cap: taking 1 of 3 pending fetches"* ]]
    [[ "$output" != *"UNHEALTHY"* ]]
    # Exactly one of the three was fetched this tick.
    n=0
    for id in BAT1------- BAT2------- BAT3-------; do
        [ -s "$ROOT/$id/.transcript/transcript.json" ] && n=$((n + 1))
    done
    [ "$n" -eq 1 ]
}

@test "--dry-run surfaces an orphaned config without touching alert state" {
    no_channels_config
    set_cursor natebjones "PREV-------"
    mark_processed "PREV-------"
    set_playlist ""

    run_ingest --dry-run

    [ "$status" -eq 1 ]
    [[ "$output" == *"channels config MISSING"* ]]
    [[ "$output" == *"dry run: would report [problem]"* ]]
    [ -z "$(reported)" ]
}
