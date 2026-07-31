#!/usr/bin/env bats
# Tests for build-index.sh: TL;DR extraction, legacy fallback, pipe escaping,
# and newest-first date sorting.

load lib

# Create a video dir: <id> <upload_date> <title> <slug> <synopsis-body>.
make_video() {
    local id="$1" date="$2" title="$3" slug="$4" body="$5"
    mkdir -p "$ROOT/$id"
    jq -n --arg t "$title" --arg d "$date" \
        --arg u "https://www.youtube.com/watch?v=$id" \
        '{title:$t, channel:"chan", upload_date:$d, duration:120, webpage_url:$u}' \
        > "$ROOT/$id/meta.json"
    printf '%s\n' "$body" > "$ROOT/$id/$slug"
}

run_build() {
    run "$YTT_GO_BIN" build-index
}

@test "TL;DR line is extracted into the index" {
    make_video AAAAAAAAAAA 20260101 "First" first.md \
        "# First
**TL;DR**: This is the summary line.

## Synopsis
Body text here."
    run_build
    [ "$status" -eq 0 ]
    grep -Fq "This is the summary line." "$ROOT/youtube-knowledge-base.md"
    grep -Fq "(AAAAAAAAAAA/first.md)" "$ROOT/youtube-knowledge-base.md"
}

@test "legacy entry without TL;DR falls back to first synopsis sentence" {
    make_video BBBBBBBBBBB 20260101 "Legacy" legacy.md \
        "# Legacy

## Synopsis
The first sentence stands in. A second one is dropped."
    run_build
    [ "$status" -eq 0 ]
    grep -Fq "The first sentence stands in." "$ROOT/youtube-knowledge-base.md"
    ! grep -Fq "A second one is dropped" "$ROOT/youtube-knowledge-base.md"
}

@test "pipes in title and TL;DR are escaped so the table survives" {
    make_video CCCCCCCCCCC 20260101 "Title | with pipe" piped.md \
        "# Title | with pipe
**TL;DR**: Summary | with | pipes.

## Synopsis
Body."
    run_build
    [ "$status" -eq 0 ]
    grep -Fq 'Title \| with pipe' "$ROOT/youtube-knowledge-base.md"
    grep -Fq 'Summary \| with \| pipes.' "$ROOT/youtube-knowledge-base.md"
}

@test "rows are sorted newest-first by upload date" {
    make_video DDDDDDDDDDD 20260101 "Older" older.md \
        "# Older
**TL;DR**: old.
## Synopsis
x."
    make_video EEEEEEEEEEE 20260601 "Newer" newer.md \
        "# Newer
**TL;DR**: new.
## Synopsis
x."
    run_build
    [ "$status" -eq 0 ]
    older_line=$(grep -n 'Older' "$ROOT/youtube-knowledge-base.md" | cut -d: -f1)
    newer_line=$(grep -n 'Newer' "$ROOT/youtube-knowledge-base.md" | cut -d: -f1)
    (( newer_line < older_line ))
}
