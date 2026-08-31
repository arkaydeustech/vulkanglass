#!/usr/bin/env python3
"""Build Vulkan Glass and install it in the local Applications folder."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")
DERIVED = ROOT / "build" / "install"
APP_NAME = "VulkanGlass.app"
EXPECTED_BUNDLE_ID = "app.vulkanglass.desktop"
STAGING_PREFIX = f".{APP_NAME}.install-"
BACKUP_NAME = f"Previous-{APP_NAME}"
QUIT_TIMEOUT_SECONDS = 10.0
QUIT_POLL_INTERVAL_SECONDS = 0.25


class InstallRecoveryError(RuntimeError):
    """An installation failed and its backup must be recovered manually."""


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.check_call(
        cmd,
        cwd=ROOT,
        env={**os.environ, "DEVELOPER_DIR": str(DEVELOPER_DIR)},
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--applications-dir",
        type=Path,
        default=Path("/Applications"),
        metavar="DIR",
        help="installation directory (default: /Applications)",
    )
    return parser.parse_args()


def validate_app(app: Path) -> None:
    executable = app / "Contents" / "MacOS" / "VulkanGlass"
    info_plist = app / "Contents" / "Info.plist"
    if not executable.is_file() or not info_plist.is_file():
        sys.exit(f"Built app is incomplete: {app}")

    bundle_id = subprocess.check_output(
        ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(info_plist)],
        text=True,
    ).strip()
    if bundle_id != EXPECTED_BUNDLE_ID:
        sys.exit(f"Unexpected bundle identifier {bundle_id!r} in {app}")

    run(["codesign", "--verify", "--deep", "--strict", str(app)])


def path_exists(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def invoking_uid() -> int:
    """Return the original user's UID, including when invoked through sudo."""
    sudo_uid = os.environ.get("SUDO_UID")
    if os.geteuid() == 0 and sudo_uid is not None:
        try:
            return int(sudo_uid)
        except ValueError:
            pass
    return os.getuid()


def running_app_pids(destination: Path, uid: int | None = None) -> list[int]:
    """Find only this user's process launched from the destination bundle."""
    executable = (destination / "Contents" / "MacOS" / "VulkanGlass").resolve()
    process_uid = invoking_uid() if uid is None else uid
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,uid=,comm=", "-ww"],
        text=True,
    )

    matches: list[int] = []
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        pid_text, uid_text, command = fields
        try:
            pid = int(pid_text)
            command_uid = int(uid_text)
        except ValueError:
            continue
        if command_uid == process_uid and Path(command).resolve() == executable:
            matches.append(pid)
    return matches


def quit_running_app(
    destination: Path,
    timeout: float = QUIT_TIMEOUT_SECONDS,
    poll_interval: float = QUIT_POLL_INTERVAL_SECONDS,
) -> None:
    """Ask the installed copy to quit, without ever force-killing it."""
    if not running_app_pids(destination):
        return

    # Address the exact bundle path so development copies with the same name are
    # not selected. json.dumps produces a safely quoted AppleScript string.
    script = (
        "tell application "
        f"{json.dumps(str(destination), ensure_ascii=False)} to quit"
    )
    result = subprocess.run(
        ["osascript", "-e", script],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "AppleScript could not request termination"
        sys.exit(f"Could not quit Vulkan Glass at {destination}: {detail}")

    deadline = time.monotonic() + timeout
    while running_app_pids(destination):
        if time.monotonic() >= deadline:
            sys.exit(
                "Vulkan Glass did not quit. It may be protecting unsaved changes. "
                "Save or discard those changes, quit the app manually, and rerun "
                "the installer. The app was not force-quit."
            )
        time.sleep(poll_interval)


def cleanup_stale_staging(destination_dir: Path, destination: Path) -> None:
    """Recover or safely remove staging directories left by interrupted runs."""
    stale_dirs = sorted(destination_dir.glob(f"{STAGING_PREFIX}*"))
    if not stale_dirs:
        return

    unexpected = [path for path in stale_dirs if path.is_symlink() or not path.is_dir()]
    if unexpected:
        paths = ", ".join(str(path) for path in unexpected)
        sys.exit(f"Refusing to remove unexpected installer staging paths: {paths}")

    backups = [path / BACKUP_NAME for path in stale_dirs if path_exists(path / BACKUP_NAME)]
    if not path_exists(destination) and backups:
        if len(backups) != 1:
            paths = ", ".join(str(path) for path in backups)
            sys.exit(
                "The installed app is missing and multiple recoverable backups "
                f"were found. Restore one manually before continuing: {paths}"
            )
        backup = backups[0]
        try:
            backup.rename(destination)
        except BaseException as error:
            raise InstallRecoveryError(
                f"Could not restore the previous app. Its backup remains at {backup}: "
                f"{error}"
            ) from error

    # Never discard a backup unless a valid app is present at the destination.
    if backups:
        if not path_exists(destination):
            paths = ", ".join(str(path) for path in backups)
            sys.exit(f"Recoverable app backups were preserved at: {paths}")
        validate_app(destination)

    for stale_dir in stale_dirs:
        shutil.rmtree(stale_dir)


def install_app(source: Path, applications_dir: Path) -> Path:
    destination_dir = applications_dir.expanduser().resolve()
    if not destination_dir.is_dir():
        sys.exit(f"Applications directory does not exist: {destination_dir}")

    destination = destination_dir / APP_NAME
    staging_dir: Path | None = None
    preserve_staging = False

    try:
        cleanup_stale_staging(destination_dir, destination)
        staging_dir = Path(
            tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=destination_dir)
        )
        staged_app = staging_dir / APP_NAME
        backup = staging_dir / BACKUP_NAME
        run(["ditto", str(source), str(staged_app)])
        validate_app(staged_app)

        quit_running_app(destination)
        try:
            if path_exists(destination):
                destination.rename(backup)
            staged_app.rename(destination)
        except BaseException as install_error:
            if path_exists(backup):
                if not path_exists(destination):
                    try:
                        backup.rename(destination)
                    except BaseException as restore_error:
                        preserve_staging = True
                        raise InstallRecoveryError(
                            "Installing the new app failed, and restoring the previous "
                            f"app also failed. The backup remains at {backup}. "
                            f"Restore error: {restore_error}"
                        ) from install_error
                elif path_exists(staged_app):
                    # Something appeared at the destination before the staged app
                    # could be installed. Preserve the old app for manual recovery.
                    preserve_staging = True
                    raise InstallRecoveryError(
                        "Installing the new app failed because the destination became "
                        f"occupied. The previous app remains at {backup}."
                    ) from install_error
            raise

        return destination
    except PermissionError:
        sys.exit(
            f"Permission denied while installing in {destination_dir}. "
            "Use an administrator account, or install into a writable directory "
            "with --applications-dir. Do not run the entire installer with sudo."
        )
    finally:
        if staging_dir is not None and staging_dir.exists() and not preserve_staging:
            shutil.rmtree(staging_dir)


def refuse_elevated_execution() -> None:
    if os.geteuid() == 0:
        sys.exit(
            "Do not run this installer as root or with sudo. Run it from an "
            "administrator account, or use --applications-dir with a writable folder."
        )


def main() -> None:
    args = parse_args()
    refuse_elevated_execution()
    if not DEVELOPER_DIR.exists():
        sys.exit("Xcode.app not found at /Applications/Xcode.app")

    run([sys.executable, str(ROOT / "scripts" / "generate_xcodeproj.py")])
    if DERIVED.exists():
        shutil.rmtree(DERIVED)
    run(
        [
            "xcodebuild",
            "-project",
            "VulkanGlass.xcodeproj",
            "-scheme",
            "VulkanGlass",
            "-configuration",
            "Release",
            "-derivedDataPath",
            str(DERIVED),
            "build",
        ]
    )

    app = DERIVED / "Build" / "Products" / "Release" / APP_NAME
    if not app.is_dir():
        sys.exit(f"Built app not found at {app}")
    validate_app(app)

    installed = install_app(app, args.applications_dir)
    print(f"Installed Vulkan Glass at {installed}")


if __name__ == "__main__":
    main()
