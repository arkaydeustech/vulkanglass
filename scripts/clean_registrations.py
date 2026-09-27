#!/usr/bin/env python3
"""Unregister development builds of Vulkan Glass from Launch Services.

Xcode registers each built app and its Quick Look extension. Use this before
deleting a worktree, or --all to sweep development builds across the machine.
Installed copies outside build directories are kept.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
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


def is_development_copy(app: Path) -> bool:
    """Recognize Xcode products, including products in deleted worktrees."""
    parts = app.parts
    return any(
        parts[index : index + 2] == ("Build", "Products")
        for index in range(len(parts) - 1)
    )


def select(apps: list[Path], scope: Path | None) -> list[Path]:
    """Select registered development builds, optionally limited to a directory."""
    return [
        app
        for app in apps
        if is_development_copy(app) and (scope is None or app.resolve().is_relative_to(scope.resolve()))
    ]


def run_command(command: list[str]) -> bool:
    """Run a registration command and report errors even in quiet mode."""
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
    except OSError as error:
        print(f"Registration command failed: {' '.join(command)}: {error}", file=sys.stderr)
        return False
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        print(f"Registration command failed: {' '.join(command)}: {detail}", file=sys.stderr)
        return False
    return True


def unregister(app: Path) -> bool:
    plugin_removed = run_command(["pluginkit", "-r", str(app / APPEX)])
    app_removed = run_command([str(LSREGISTER), "-u", str(app)])
    return plugin_removed and app_removed


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument(
        "--all",
        action="store_true",
        help="unregister development builds across this Mac, not just this checkout's",
    )
    scope.add_argument(
        "--scope",
        type=Path,
        metavar="DIR",
        help="unregister only development builds inside this directory",
    )
    parser.add_argument("--dry-run", action="store_true", help="list the copies without unregistering them")
    parser.add_argument("--quiet", action="store_true", help="suppress the no-matches message")
    return parser.parse_args(argv)


def registration_dump() -> str:
    return subprocess.run([str(LSREGISTER), "-dump"], check=True, capture_output=True, text=True).stdout


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        registered = registered_apps(registration_dump())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Could not read Launch Services registrations: {error}", file=sys.stderr)
        return 1

    scope = None if args.all else (args.scope or ROOT).expanduser().resolve()
    apps = select(registered, scope)
    if not apps:
        if not args.quiet:
            print("No development copies of Vulkan Glass are registered.")
        return 0

    if args.dry_run:
        for app in apps:
            print(f"Would unregister {app}")
        return 0

    success = True
    for app in apps:
        print(f"Unregistering {app}")
        success = unregister(app) and success

    # Refresh installed copies after removing builds. Include the standard path
    # even if Launch Services had not listed it in the original dump.
    installed = {app for app in registered if not is_development_copy(app)}
    installed.add(INSTALLED)
    for app in sorted(installed):
        if app.exists():
            success = run_command([str(LSREGISTER), "-f", str(app)]) and success

    try:
        remaining = set(registered_apps(registration_dump())).intersection(apps)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Could not verify Launch Services registrations: {error}", file=sys.stderr)
        return 1
    for app in sorted(remaining):
        print(f"Registration remains: {app}", file=sys.stderr)
    return 0 if success and not remaining else 1


if __name__ == "__main__":
    sys.exit(main())
