from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import install


class InstallerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.applications_dir = self.root / "Applications"
        self.applications_dir.mkdir()
        self.source = self.root / "Source" / install.APP_NAME
        self.make_app(self.source, "NEW")

    def make_app(self, path: Path, marker: str) -> None:
        executable = path / "Contents" / "MacOS" / "VulkanGlass"
        executable.parent.mkdir(parents=True)
        executable.write_text(marker)
        (path / "Contents" / "Info.plist").write_text("plist")

    def marker(self, app: Path) -> str:
        return (app / "Contents" / "MacOS" / "VulkanGlass").read_text()

    def fake_run(self, command: list[str]) -> None:
        if command[0] == "ditto":
            shutil.copytree(command[1], command[2], symlinks=True)

    def install_patches(self):
        return (
            mock.patch.object(install, "run", side_effect=self.fake_run),
            mock.patch.object(install, "validate_app"),
            mock.patch.object(install, "quit_running_app"),
        )


class InstallAppTests(InstallerTestCase):
    def test_fresh_install(self) -> None:
        run_patch, validate_patch, quit_patch = self.install_patches()
        with run_patch, validate_patch, quit_patch:
            destination = install.install_app(self.source, self.applications_dir)

        self.assertEqual(self.marker(destination), "NEW")
        self.assertEqual(
            sorted(path.name for path in self.applications_dir.iterdir()),
            [install.APP_NAME],
        )

    def test_existing_app_is_replaced(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        self.make_app(destination, "OLD")
        run_patch, validate_patch, quit_patch = self.install_patches()
        with run_patch, validate_patch, quit_patch:
            install.install_app(self.source, self.applications_dir)

        self.assertEqual(self.marker(destination), "NEW")
        self.assertEqual(
            list(self.applications_dir.glob(f"{install.STAGING_PREFIX}*")), []
        )

    def test_staged_validation_failure_leaves_existing_app_untouched(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        self.make_app(destination, "OLD")

        with (
            mock.patch.object(install, "run", side_effect=self.fake_run),
            mock.patch.object(
                install, "validate_app", side_effect=SystemExit("invalid staged app")
            ),
            mock.patch.object(install, "quit_running_app") as quit_app,
            self.assertRaisesRegex(SystemExit, "invalid staged app"),
        ):
            install.install_app(self.source, self.applications_dir)

        self.assertEqual(self.marker(destination), "OLD")
        self.assertEqual(
            list(self.applications_dir.glob(f"{install.STAGING_PREFIX}*")), []
        )
        quit_app.assert_not_called()

    def test_permission_failure_has_safe_guidance(self) -> None:
        with (
            mock.patch.object(
                install.tempfile,
                "mkdtemp",
                side_effect=PermissionError("not writable"),
            ),
            self.assertRaises(SystemExit) as raised,
        ):
            install.install_app(self.source, self.applications_dir)

        message = str(raised.exception)
        self.assertIn("--applications-dir", message)
        self.assertIn("Do not run the entire installer with sudo", message)

    def test_failed_final_rename_restores_previous_app(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        self.make_app(destination, "OLD")
        original_rename = Path.rename

        def fail_staged_rename(path: Path, target: Path) -> Path:
            if path.name == install.APP_NAME and path.parent.name.startswith(
                install.STAGING_PREFIX
            ):
                raise OSError("injected install failure")
            return original_rename(path, target)

        run_patch, validate_patch, quit_patch = self.install_patches()
        with (
            run_patch,
            validate_patch,
            quit_patch,
            mock.patch.object(Path, "rename", autospec=True, side_effect=fail_staged_rename),
            self.assertRaisesRegex(OSError, "injected install failure"),
        ):
            install.install_app(self.source, self.applications_dir)

        self.assertEqual(self.marker(destination), "OLD")
        self.assertEqual(
            list(self.applications_dir.glob(f"{install.STAGING_PREFIX}*")), []
        )

    def test_interrupt_after_backup_rename_restores_previous_app(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        self.make_app(destination, "OLD")
        original_rename = Path.rename

        def interrupt_after_backup(path: Path, target: Path) -> Path:
            result = original_rename(path, target)
            if (
                path.name == install.APP_NAME
                and path.parent == self.applications_dir.resolve()
                and target.name == install.BACKUP_NAME
            ):
                raise KeyboardInterrupt()
            return result

        run_patch, validate_patch, quit_patch = self.install_patches()
        with (
            run_patch,
            validate_patch,
            quit_patch,
            mock.patch.object(Path, "rename", autospec=True, side_effect=interrupt_after_backup),
            self.assertRaises(KeyboardInterrupt),
        ):
            install.install_app(self.source, self.applications_dir)

        self.assertEqual(self.marker(destination), "OLD")
        self.assertEqual(
            list(self.applications_dir.glob(f"{install.STAGING_PREFIX}*")), []
        )

    def test_failed_install_and_restore_preserve_backup(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        self.make_app(destination, "OLD")
        original_rename = Path.rename

        def fail_install_and_restore(path: Path, target: Path) -> Path:
            if (
                path.name in {install.APP_NAME, install.BACKUP_NAME}
                and target.name == install.APP_NAME
                and target.parent == self.applications_dir.resolve()
            ):
                raise OSError(f"injected failure for {path.name}")
            return original_rename(path, target)

        run_patch, validate_patch, quit_patch = self.install_patches()
        with (
            run_patch,
            validate_patch,
            quit_patch,
            mock.patch.object(
                Path, "rename", autospec=True, side_effect=fail_install_and_restore
            ),
            self.assertRaises(install.InstallRecoveryError) as raised,
        ):
            install.install_app(self.source, self.applications_dir)

        backups = list(
            self.applications_dir.glob(
                f"{install.STAGING_PREFIX}*/{install.BACKUP_NAME}"
            )
        )
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.marker(backups[0]), "OLD")
        self.assertIn(str(backups[0]), str(raised.exception))
        self.assertFalse(destination.exists())

    def test_destination_race_preserves_backup(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        self.make_app(destination, "OLD")
        original_rename = Path.rename

        def occupy_destination(path: Path, target: Path) -> Path:
            if path.name == install.APP_NAME and path.parent.name.startswith(
                install.STAGING_PREFIX
            ):
                self.make_app(destination, "COMPETING")
                raise FileExistsError("destination occupied")
            return original_rename(path, target)

        run_patch, validate_patch, quit_patch = self.install_patches()
        with (
            run_patch,
            validate_patch,
            quit_patch,
            mock.patch.object(Path, "rename", autospec=True, side_effect=occupy_destination),
            self.assertRaises(install.InstallRecoveryError),
        ):
            install.install_app(self.source, self.applications_dir)

        backup = next(
            self.applications_dir.glob(
                f"{install.STAGING_PREFIX}*/{install.BACKUP_NAME}"
            )
        )
        self.assertEqual(self.marker(backup), "OLD")
        self.assertEqual(self.marker(destination), "COMPETING")


class StaleStagingTests(InstallerTestCase):
    def test_stale_directory_without_backup_is_removed(self) -> None:
        stale = self.applications_dir / f"{install.STAGING_PREFIX}stale"
        self.make_app(stale / install.APP_NAME, "STAGED")

        install.cleanup_stale_staging(
            self.applications_dir, self.applications_dir / install.APP_NAME
        )

        self.assertFalse(stale.exists())

    def test_single_backup_is_recovered_when_destination_is_missing(self) -> None:
        stale = self.applications_dir / f"{install.STAGING_PREFIX}stale"
        backup = stale / install.BACKUP_NAME
        self.make_app(backup, "OLD")
        destination = self.applications_dir / install.APP_NAME

        with mock.patch.object(install, "validate_app") as validate:
            install.cleanup_stale_staging(self.applications_dir, destination)

        self.assertEqual(self.marker(destination), "OLD")
        self.assertFalse(stale.exists())
        validate.assert_called_once_with(destination)

    def test_multiple_backups_are_preserved_when_destination_is_missing(self) -> None:
        backups = []
        for suffix in ("one", "two"):
            stale = self.applications_dir / f"{install.STAGING_PREFIX}{suffix}"
            backup = stale / install.BACKUP_NAME
            self.make_app(backup, suffix)
            backups.append(backup)

        with self.assertRaisesRegex(SystemExit, "multiple recoverable backups"):
            install.cleanup_stale_staging(
                self.applications_dir, self.applications_dir / install.APP_NAME
            )

        self.assertTrue(all(backup.exists() for backup in backups))

    def test_existing_destination_is_validated_before_backup_cleanup(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        self.make_app(destination, "CURRENT")
        stale = self.applications_dir / f"{install.STAGING_PREFIX}stale"
        backup = stale / install.BACKUP_NAME
        self.make_app(backup, "OLD")

        with (
            mock.patch.object(
                install, "validate_app", side_effect=SystemExit("invalid destination")
            ),
            self.assertRaisesRegex(SystemExit, "invalid destination"),
        ):
            install.cleanup_stale_staging(self.applications_dir, destination)

        self.assertEqual(self.marker(backup), "OLD")

    def test_unexpected_staging_symlink_is_not_followed(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        marker = outside / "keep"
        marker.write_text("safe")
        stale = self.applications_dir / f"{install.STAGING_PREFIX}link"
        stale.symlink_to(outside, target_is_directory=True)

        with self.assertRaisesRegex(SystemExit, "unexpected installer staging"):
            install.cleanup_stale_staging(
                self.applications_dir, self.applications_dir / install.APP_NAME
            )

        self.assertEqual(marker.read_text(), "safe")
        self.assertTrue(stale.is_symlink())


class ValidateAppTests(InstallerTestCase):
    def test_missing_required_files_are_rejected(self) -> None:
        cases = {
            "missing executable": self.root / "MissingExecutable.app",
            "missing plist": self.root / "MissingPlist.app",
        }
        (cases["missing executable"] / "Contents").mkdir(parents=True)
        (cases["missing executable"] / "Contents" / "Info.plist").write_text("plist")
        executable = cases["missing plist"] / "Contents" / "MacOS" / "VulkanGlass"
        executable.parent.mkdir(parents=True)
        executable.write_text("binary")

        for label, app in cases.items():
            with self.subTest(label), self.assertRaisesRegex(SystemExit, "incomplete"):
                install.validate_app(app)

    def test_wrong_bundle_identifier_is_rejected_before_codesign(self) -> None:
        with (
            mock.patch.object(
                install.subprocess,
                "check_output",
                return_value="example.wrong.bundle\n",
            ),
            mock.patch.object(install, "run") as run,
            self.assertRaisesRegex(SystemExit, "Unexpected bundle identifier"),
        ):
            install.validate_app(self.source)

        run.assert_not_called()

    def test_codesign_failure_is_propagated(self) -> None:
        error = subprocess.CalledProcessError(1, ["codesign"])
        with (
            mock.patch.object(
                install.subprocess,
                "check_output",
                return_value=f"{install.EXPECTED_BUNDLE_ID}\n",
            ),
            mock.patch.object(install, "run", side_effect=error) as run,
            self.assertRaises(subprocess.CalledProcessError),
        ):
            install.validate_app(self.source)

        run.assert_called_once()


class ProcessHandlingTests(InstallerTestCase):
    def test_process_lookup_matches_only_uid_and_destination_executable(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        executable = destination / "Contents" / "MacOS" / "VulkanGlass"
        debug_executable = (
            self.root
            / "Debug"
            / install.APP_NAME
            / "Contents"
            / "MacOS"
            / "VulkanGlass"
        )
        process_table = "\n".join(
            [
                f"101 501 {executable}",
                f"102 502 {executable}",
                f"103 501 {debug_executable}",
                "malformed row",
            ]
        )

        with mock.patch.object(
            install.subprocess, "check_output", return_value=process_table
        ):
            pids = install.running_app_pids(destination, uid=501)

        self.assertEqual(pids, [101])

    def test_no_running_destination_skips_applescript(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        with (
            mock.patch.object(install, "running_app_pids", return_value=[]),
            mock.patch.object(install.subprocess, "run") as run,
        ):
            install.quit_running_app(destination)

        run.assert_not_called()

    def test_graceful_quit_waits_for_exit(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        completed = subprocess.CompletedProcess([], 0, "", "")
        with (
            mock.patch.object(
                install, "running_app_pids", side_effect=[[123], [123], []]
            ),
            mock.patch.object(install.subprocess, "run", return_value=completed) as run,
            mock.patch.object(install.time, "sleep") as sleep,
        ):
            install.quit_running_app(destination, timeout=10, poll_interval=0.01)

        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["osascript", "-e"])
        self.assertIn(str(destination), command[2])
        sleep.assert_called_once_with(0.01)

    def test_declined_quit_aborts_without_force_kill(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        completed = subprocess.CompletedProcess([], 0, "", "")
        with (
            mock.patch.object(install, "running_app_pids", return_value=[123]),
            mock.patch.object(install.subprocess, "run", return_value=completed) as run,
            mock.patch.object(install.time, "monotonic", side_effect=[0.0, 1.0]),
            self.assertRaisesRegex(SystemExit, "not force-quit"),
        ):
            install.quit_running_app(destination, timeout=0.5, poll_interval=0)

        self.assertEqual(run.call_count, 1)
        self.assertNotIn("killall", run.call_args.args[0])

    def test_applescript_failure_aborts_with_detail(self) -> None:
        destination = self.applications_dir / install.APP_NAME
        completed = subprocess.CompletedProcess([], 1, "", "permission denied")
        with (
            mock.patch.object(install, "running_app_pids", return_value=[123]),
            mock.patch.object(install.subprocess, "run", return_value=completed),
            self.assertRaisesRegex(SystemExit, "permission denied"),
        ):
            install.quit_running_app(destination)

    def test_sudo_uid_is_used_for_process_scope(self) -> None:
        with (
            mock.patch.object(install.os, "geteuid", return_value=0),
            mock.patch.dict(os.environ, {"SUDO_UID": "501"}),
        ):
            self.assertEqual(install.invoking_uid(), 501)

    def test_elevated_execution_is_rejected(self) -> None:
        with (
            mock.patch.object(install.os, "geteuid", return_value=0),
            self.assertRaisesRegex(SystemExit, "Do not run this installer as root"),
        ):
            install.refuse_elevated_execution()


if __name__ == "__main__":
    unittest.main()
