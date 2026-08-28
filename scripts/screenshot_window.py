#!/usr/bin/env python3
"""Capture a named Mac window to PNG via screencapture -l (no Ruby)."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "scripts" / "window_id.swift"
BIN = ROOT / "build" / "window_id"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: screenshot_window.py <owner-substring> <output.png>")
    BIN.parent.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "DEVELOPER_DIR": DEVELOPER_DIR}
    if not BIN.exists() or SRC.stat().st_mtime > BIN.stat().st_mtime:
        subprocess.check_call(["swiftc", "-O", "-o", str(BIN), str(SRC)], env=env)
    window_id = subprocess.check_output([str(BIN), sys.argv[1]], text=True).strip()
    subprocess.check_call(["screencapture", "-x", "-l", window_id, sys.argv[2]])
    print(sys.argv[2])


if __name__ == "__main__":
    main()
