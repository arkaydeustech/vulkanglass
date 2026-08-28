#!/usr/bin/env python3
"""Build and launch the native Vulkan Glass Mac app using Xcode (no Ruby)."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")
DERIVED = ROOT / "build"


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.check_call(cmd, cwd=ROOT, env={**os.environ, "DEVELOPER_DIR": str(DEVELOPER_DIR)})


def main() -> None:
    if not DEVELOPER_DIR.exists():
        sys.exit("Xcode.app not found at /Applications/Xcode.app")
    run([sys.executable, str(ROOT / "scripts" / "generate_xcodeproj.py")])
    if DERIVED.exists():
        subprocess.check_call(["rm", "-rf", str(DERIVED)])
    run(
        [
            "xcodebuild",
            "-project",
            "VulkanGlass.xcodeproj",
            "-scheme",
            "VulkanGlass",
            "-configuration",
            "Debug",
            "-derivedDataPath",
            str(DERIVED),
        ]
    )
    apps = list(DERIVED.glob("**/VulkanGlass.app"))
    if not apps:
        sys.exit("Built app not found")
    app = max(apps, key=lambda p: p.stat().st_mtime)
    print(f"Launching {app}")
    # Launch Services reuses a running copy of the same bundle ID; quit it first.
    subprocess.run(
        ["osascript", "-e", 'tell application "Vulkan Glass" to quit'],
        check=False,
        capture_output=True,
    )
    subprocess.run(["killall", "VulkanGlass"], check=False, capture_output=True)
    subprocess.check_call(["open", "-n", str(app)])


if __name__ == "__main__":
    main()
