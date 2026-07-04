# Copyright 2026 Marcelo Cantos
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for the ytt CLI module.

These replace the inline `python -c` asserts that previously lived only in
ci.yml — invisible in the repo and not runnable locally. Run with `pytest`
or `make test`.
"""

from __future__ import annotations

import json

import pytest

import ytt


class TestExtractVideoId:
    @pytest.mark.parametrize(
        ("arg", "expected"),
        [
            ("dQw4w9WgXcQ", "dQw4w9WgXcQ"),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30s", "dQw4w9WgXcQ"),
            ("https://youtu.be/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
            ("https://youtu.be/dQw4w9WgXcQ?t=30", "dQw4w9WgXcQ"),
            ("https://youtube.com/shorts/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
            ("https://www.youtube.com/embed/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ],
    )
    def test_forms(self, arg: str, expected: str) -> None:
        assert ytt.extract_video_id(arg) == expected


class TestFormatTimestamp:
    @pytest.mark.parametrize(
        ("seconds", "expected"),
        [
            (0, "[00:00]"),
            (65, "[01:05]"),
            (3600, "[1:00:00]"),
            (3661, "[1:01:01]"),
        ],
    )
    def test_values(self, seconds: int, expected: str) -> None:
        assert ytt.format_timestamp(seconds) == expected


class TestCliArgHandling:
    def test_no_args_exits_2(self) -> None:
        with pytest.raises(SystemExit) as exc:
            ytt.main([])
        assert exc.value.code == 2

    def test_version_exits_0(self, capsys: pytest.CaptureFixture[str]) -> None:
        with pytest.raises(SystemExit) as exc:
            ytt.main(["--version"])
        assert exc.value.code == 0
        assert capsys.readouterr().out.startswith("ytt ")

    def test_timestamps_and_json_are_mutually_exclusive(self) -> None:
        with pytest.raises(SystemExit) as exc:
            ytt.main(["-t", "--json", "dQw4w9WgXcQ"])
        assert exc.value.code == 2

    def test_help_agent(self, capsys: pytest.CaptureFixture[str]) -> None:
        assert ytt.main(["--help-agent"]) == 0
        out = capsys.readouterr().out
        assert "ytt" in out and "Exit codes" in out

    def test_plain_mode_separates_videos_with_blank_line(
        self, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(ytt, "fetch_transcript", lambda vid, mode: f"T[{vid}]")
        assert ytt.main(["aaaaaaaaaaa", "bbbbbbbbbbb"]) == 0
        assert capsys.readouterr().out == "T[aaaaaaaaaaa]\n\nT[bbbbbbbbbbb]\n"

    def test_json_mode_is_jsonl_no_blank_line(
        self, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            ytt, "fetch_transcript", lambda vid, mode: json.dumps({"video_id": vid})
        )
        assert ytt.main(["--json", "aaaaaaaaaaa", "bbbbbbbbbbb"]) == 0
        lines = capsys.readouterr().out.splitlines()
        assert [json.loads(x)["video_id"] for x in lines] == [
            "aaaaaaaaaaa",
            "bbbbbbbbbbb",
        ]

    def test_fetch_failure_sets_exit_1_but_continues(
        self, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
    ) -> None:
        def fake(vid: str, mode: str) -> str:
            if vid == "bad00000000":
                raise RuntimeError("boom")
            return f"T[{vid}]"

        monkeypatch.setattr(ytt, "fetch_transcript", fake)
        # First video fails, second still fetched; overall exit code is 1.
        assert ytt.main(["bad00000000", "good0000000"]) == 1
        captured = capsys.readouterr()
        assert "ytt: bad00000000:" in captured.err
        assert "T[good0000000]" in captured.out
