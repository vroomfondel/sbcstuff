"""Tests for repo_scripts/blurimage.py argument parsing."""

import argparse
import sys
import types
from unittest.mock import patch

import pytest

# blurimage.py auto-installs pytesseract/cv2 and checks for tesseract at import time.
# Mock those away so tests run without system dependencies.
_mock_pytesseract: types.ModuleType = types.ModuleType("pytesseract")
_mock_pytesseract.Output = type("Output", (), {"DICT": "dict"})  # type: ignore[attr-defined]
_mock_pytesseract.image_to_data = lambda *a, **kw: {}  # type: ignore[attr-defined]
sys.modules.setdefault("pytesseract", _mock_pytesseract)

_mock_cv2: types.ModuleType = types.ModuleType("cv2")
sys.modules.setdefault("cv2", _mock_cv2)

_mock_numpy: types.ModuleType = types.ModuleType("numpy")
sys.modules.setdefault("numpy", _mock_numpy)

with patch("shutil.which", return_value="/usr/bin/tesseract"):
    from repo_scripts.blurimage import build_parser


@pytest.fixture
def parser() -> argparse.ArgumentParser:
    return build_parser()


class TestBlurimageArgparse:
    """Test argument parsing for blurimage.py."""

    def test_image_before_blur(self, parser: argparse.ArgumentParser) -> None:
        """Positional BEFORE flags — the recommended usage pattern."""
        args: argparse.Namespace = parser.parse_args(["screenshot.png", "--blur", "myuser"])
        assert args.image == "screenshot.png"
        assert args.blur == ["myuser"]

    def test_image_before_blur_regex(self, parser: argparse.ArgumentParser) -> None:
        """Positional before --blur-regex avoids greedy nargs="+" entirely."""
        args: argparse.Namespace = parser.parse_args(["screenshot.png", "--blur-regex", r"rVFe\S+", "[A-Z]{8,}"])
        assert args.image == "screenshot.png"
        assert args.blur_regex == [r"rVFe\S+", "[A-Z]{8,}"]

    def test_image_before_all_flags(self, parser: argparse.ArgumentParser) -> None:
        """Full usage: image first, then --blur and --blur-regex."""
        args: argparse.Namespace = parser.parse_args(
            ["screenshot.png", "--blur", "myuser", "--blur-regex", r"\S+secret"]
        )
        assert args.image == "screenshot.png"
        assert args.blur == ["myuser"]
        assert args.blur_regex == [r"\S+secret"]

    def test_separator_with_blur_regex(self, parser: argparse.ArgumentParser) -> None:
        """Using -- separator prevents nargs="+" from swallowing the image."""
        args: argparse.Namespace = parser.parse_args(["--blur-regex", r"rVFe\S+", "[A-Z]{8,}", "--", "screenshot.png"])
        assert args.blur_regex == [r"rVFe\S+", "[A-Z]{8,}"]
        assert args.image == "screenshot.png"

    def test_separator_with_blur(self, parser: argparse.ArgumentParser) -> None:
        """-- separator also works with --blur."""
        args: argparse.Namespace = parser.parse_args(["--blur", "myuser", "elasticc.io", "--", "screenshot.png"])
        assert args.blur == ["myuser", "elasticc.io"]
        assert args.image == "screenshot.png"

    def test_blur_and_blur_regex_with_separator(self, parser: argparse.ArgumentParser) -> None:
        args: argparse.Namespace = parser.parse_args(
            ["--blur", "myuser", "--blur-regex", r"secret\S+", "--", "screenshot.png"]
        )
        assert args.blur == ["myuser"]
        assert args.blur_regex == [r"secret\S+"]
        assert args.image == "screenshot.png"

    def test_image_is_required(self, parser: argparse.ArgumentParser) -> None:
        """image is a required positional — no stale hardcoded default."""
        with pytest.raises(SystemExit, match="2"):
            parser.parse_args(["--blur", "myuser"])

    def test_greedy_nargs_swallows_trailing_image(self, parser: argparse.ArgumentParser) -> None:
        """Documents the known argparse limitation: --blur nargs="+" eats trailing positional."""
        with pytest.raises(SystemExit, match="2"):
            # --blur consumes both "myuser" AND "screenshot.png", leaving no positional
            parser.parse_args(["--blur", "myuser", "screenshot.png"])

    def test_no_blur_flags_accepted_by_parser(self, parser: argparse.ArgumentParser) -> None:
        """Parser itself accepts no --blur/--blur-regex; main() validates this separately."""
        args: argparse.Namespace = parser.parse_args(["screenshot.png"])
        assert args.blur == []
        assert args.blur_regex == []

    def test_defaults(self, parser: argparse.ArgumentParser) -> None:
        args: argparse.Namespace = parser.parse_args(["img.png", "--blur", "x"])
        assert args.scale == 2
        assert args.no_invert is False
        assert args.debug is False

    def test_scale_flag(self, parser: argparse.ArgumentParser) -> None:
        args: argparse.Namespace = parser.parse_args(["img.png", "--scale", "3", "--blur", "x"])
        assert args.scale == 3

    def test_debug_flag(self, parser: argparse.ArgumentParser) -> None:
        args: argparse.Namespace = parser.parse_args(["img.png", "--debug", "--blur", "x"])
        assert args.debug is True

    def test_no_invert_flag(self, parser: argparse.ArgumentParser) -> None:
        args: argparse.Namespace = parser.parse_args(["img.png", "--no-invert", "--blur", "x"])
        assert args.no_invert is True
