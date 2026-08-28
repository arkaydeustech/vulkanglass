#!/usr/bin/env python3
"""Create AppIcon.appiconset from resources/icon.png using sips (no Ruby)."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "resources" / "icon.png"
OUT = ROOT / "VulkanGlass" / "Assets.xcassets" / "AppIcon.appiconset"

SIZES = [16, 32, 128, 256, 512, 1024]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    images = []
    for size in SIZES:
        filename = f"icon_{size}.png"
        dest = OUT / filename
        subprocess.check_call(["sips", "-z", str(size), str(size), str(SRC), "--out", str(dest)], stdout=subprocess.DEVNULL)
        point = size if size != 1024 else 512
        scale = "2x" if size in (32, 256, 512, 1024) and size != 32 else "1x"
        # mac idiom entries: 16@1x, 16@2x (32), 32@1x, 32@2x (64) — keep it simple with 1x of each listed size
        images.append(
            {
                "idiom": "mac",
                "size": f"{size}x{size}" if size != 1024 else "512x512",
                "scale": "1x" if size != 1024 else "2x",
                "filename": filename,
            }
        )
    # Use a cleaner official set
    images = [
        {"idiom": "mac", "size": "16x16", "scale": "1x", "filename": "icon_16.png"},
        {"idiom": "mac", "size": "16x16", "scale": "2x", "filename": "icon_32.png"},
        {"idiom": "mac", "size": "32x32", "scale": "1x", "filename": "icon_32.png"},
        {"idiom": "mac", "size": "32x32", "scale": "2x", "filename": "icon_64.png"},
        {"idiom": "mac", "size": "128x128", "scale": "1x", "filename": "icon_128.png"},
        {"idiom": "mac", "size": "128x128", "scale": "2x", "filename": "icon_256.png"},
        {"idiom": "mac", "size": "256x256", "scale": "1x", "filename": "icon_256.png"},
        {"idiom": "mac", "size": "256x256", "scale": "2x", "filename": "icon_512.png"},
        {"idiom": "mac", "size": "512x512", "scale": "1x", "filename": "icon_512.png"},
        {"idiom": "mac", "size": "512x512", "scale": "2x", "filename": "icon_1024.png"},
    ]
    subprocess.check_call(["sips", "-z", "64", "64", str(SRC), "--out", str(OUT / "icon_64.png")], stdout=subprocess.DEVNULL)
    (OUT / "Contents.json").write_text(json.dumps({"images": images, "info": {"version": 1, "author": "xcode"}}, indent=2))
    (ROOT / "VulkanGlass" / "Assets.xcassets" / "Contents.json").write_text(
        json.dumps({"info": {"version": 1, "author": "xcode"}}, indent=2)
    )
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
