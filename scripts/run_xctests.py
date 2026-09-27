#!/usr/bin/env python3
"""Run XCTest and always clean registrations made by its derived-data build."""

from __future__ import annotations

import subprocess
import sys

from scripts import clean_registrations


def main(args: list[str] | None = None) -> int:
    status = 1
    try:
        status = subprocess.run(
            [
                "xcodebuild",
                "-project", "VulkanGlass.xcodeproj",
                "-scheme", "VulkanGlass",
                "-destination", "platform=macOS",
                "-derivedDataPath", "build/test",
                "test",
                *(sys.argv[1:] if args is None else args),
            ],
            check=False,
        ).returncode
    finally:
        try:
            cleanup_status = clean_registrations.main(
                ["--quiet", "--scope", str(clean_registrations.ROOT / "build" / "test")]
            )
            if cleanup_status != 0:
                print("Registration cleanup was incomplete.", file=sys.stderr)
        except Exception as error:
            print(f"Registration cleanup failed: {error}", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
