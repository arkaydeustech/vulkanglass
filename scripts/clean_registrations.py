#!/usr/bin/env python3
"""Unregister development copies of Vulkan Glass from Launch Services.

Every VulkanGlass.app that Xcode builds is registered with Launch Services and
PlugInKit, so each build directory adds another "VulkanGlass — Quick Look" row to
System Settings › General › Login Items & Extensions. The registrations outlive
the worktree that produced them. Run this before deleting a worktree (or with
--all to sweep every stray copy on the machine); the installed app in
/Applications is always kept.
"""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "VulkanGlass.app"
APPEX = Path("Contents/PlugIns/VulkanGlassQuickLook.appex")
INSTALLED = Path("/Applications") / APP_NAME
LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)
PATH_LINE = re.compile(r"^path:\s+(?P<path>.+/" + re.escape(APP_NAME) + r")(?:\s+\(0x[0-9a-f]+\))?$")


def registered_apps(dump: str) -> list[Path]:
    """Return every VulkanGlass.app path in an `lsregister -dump`, deduplicated."""
    paths = {Path(m["path"]) for line in dump.splitlines() if (m := PATH_LINE.match(line.strip()))}
    return sorted(paths)


def select(apps: list[Path], scope: Path | None) -> list[Path]:
    """Pick the copies to unregister: never the installed app, and only under
    `scope` when one is given."""
    chosen = []
    for app in apps:
        if app == INSTALLED:
            continue
        if scope is not None and not app.is_relative_to(scope):
            continue
        chosen.append(app)
    return chosen


def unregister(app: Path) -> None:
    subprocess.run(["pluginkit", "-r", str(app / APPEX)], check=False, capture_output=True)
    subprocess.run([str(LSREGISTER), "-u", str(app)], check=False, capture_output=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--all",
        action="store_true",
        help=f"unregister every copy on this Mac except {INSTALLED}, not just this checkout's",
    )
    parser.add_argument("--dry-run", action="store_true", help="list the copies without unregistering them")
    parser.add_argument("--quiet", action="store_true", help="only print when something was unregistered")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    dump = subprocess.run([str(LSREGISTER), "-dump"], check=True, capture_output=True, text=True).stdout
    scope = None if args.all else ROOT.resolve()
    apps = select(registered_apps(dump), scope)
    if not apps:
        if not args.quiet:
            print("No development copies of Vulkan Glass are registered.")
        return
    for app in apps:
        print(("Would unregister " if args.dry_run else "Unregistering ") + str(app))
        if not args.dry_run:
            unregister(app)
    if INSTALLED.exists() and not args.dry_run:
        # Re-register the installed copy so its Quick Look extension stays active.
        subprocess.run([str(LSREGISTER), "-f", str(INSTALLED)], check=False, capture_output=True)


if __name__ == "__main__":
    main()
