from __future__ import annotations

import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import clean_registrations as cr

DUMP = """\
bundle id:                  1234
path:                       /Applications/VulkanGlass.app (0x1a2b)
path:                       /Applications/VulkanGlass.app/Contents/PlugIns/VulkanGlassQuickLook.appex (0x1a2c)
path:                       /Users/me/Applications/VulkanGlass.app
path:                       /Users/me/custom-apps/VulkanGlass.app (0x1a2d)
path:                       /Users/me/build/VulkanGlass.app (0x1a2e)
path:                       /Users/me/work/vg/build/test/Build/Products/Debug/VulkanGlass.app (0x3c4d)
path:                       /Users/me/work/vg/build/test/Build/Products/Debug/VulkanGlass.app (0x3c4e)
path:                       /private/tmp/vg-dd/Build/Products/Debug/VulkanGlass.app (0x5e6f)
path:                       /Applications/Other.app (0x7a8b)
"""


class RegisteredAppsTests(unittest.TestCase):
    def test_parses_and_deduplicates_app_paths_with_or_without_suffix(self) -> None:
        self.assertEqual(
            cr.registered_apps(DUMP),
            [
                Path("/Applications/VulkanGlass.app"),
                Path("/Users/me/Applications/VulkanGlass.app"),
                Path("/Users/me/build/VulkanGlass.app"),
                Path("/Users/me/custom-apps/VulkanGlass.app"),
                Path("/Users/me/work/vg/build/test/Build/Products/Debug/VulkanGlass.app"),
                Path("/private/tmp/vg-dd/Build/Products/Debug/VulkanGlass.app"),
            ],
        )


class SelectTests(unittest.TestCase):
    def setUp(self) -> None:
        self.apps = cr.registered_apps(DUMP)

    def test_scope_limits_to_test_build(self) -> None:
        self.assertEqual(
            cr.select(self.apps, Path("/Users/me/work/vg/build/test")),
            [Path("/Users/me/work/vg/build/test/Build/Products/Debug/VulkanGlass.app")],
        )

    def test_all_keeps_standard_and_custom_installs(self) -> None:
        self.assertEqual(
            cr.select(self.apps, None),
            [
                Path("/Users/me/work/vg/build/test/Build/Products/Debug/VulkanGlass.app"),
                Path("/private/tmp/vg-dd/Build/Products/Debug/VulkanGlass.app"),
            ],
        )


class CommandTests(unittest.TestCase):
    def test_registration_dump_uses_lsregister(self) -> None:
        with mock.patch.object(
            cr.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "path: example", "")
        ) as run:
            self.assertEqual(cr.registration_dump(), "path: example")
        run.assert_called_once_with([str(cr.LSREGISTER), "-dump"], check=True, capture_output=True, text=True)

    def test_unregister_reports_plugin_failure_and_still_attempts_app_removal(self) -> None:
        app = Path("/tmp/work/build/VulkanGlass.app")
        results = [
            subprocess.CompletedProcess([], 1, "", "plugin still registered"),
            subprocess.CompletedProcess([], 0, "", ""),
        ]
        with mock.patch.object(cr.subprocess, "run", side_effect=results) as run:
            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertFalse(cr.unregister(app))
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0][:2], ["pluginkit", "-r"])
        self.assertEqual(run.call_args_list[1].args[0][:2], [str(cr.LSREGISTER), "-u"])
        self.assertIn("plugin still registered", stderr.getvalue())


class MainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / "build" / "test" / "Build" / "Products" / "Debug" / cr.APP_NAME
        self.other_build = self.root / "build" / "app" / "Build" / "Products" / "Debug" / cr.APP_NAME
        self.installed = self.root / "Applications" / cr.APP_NAME
        self.installed.mkdir(parents=True)
        self.custom_installed = self.root / "custom-apps" / cr.APP_NAME
        self.custom_installed.mkdir(parents=True)
        self.dump = "\n".join(f"path: {app}" for app in (self.build, self.other_build, self.installed, self.custom_installed))
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(cr, "ROOT", self.root).start()
        mock.patch.object(cr, "INSTALLED", self.installed).start()

    def test_dry_run_and_quiet_scope_do_not_remove_anything(self) -> None:
        with mock.patch.object(cr, "registration_dump", return_value=self.dump):
            with mock.patch.object(cr.subprocess, "run") as run:
                with contextlib.redirect_stdout(io.StringIO()) as stdout:
                    self.assertEqual(cr.main(["--scope", str(self.root / "build" / "test"), "--dry-run", "--quiet"]), 0)
        self.assertIn(f"Would unregister {self.build}", stdout.getvalue())
        self.assertNotIn(str(self.other_build), stdout.getvalue())
        run.assert_not_called()

    def test_quiet_with_no_matches_prints_nothing(self) -> None:
        with mock.patch.object(cr, "registration_dump", return_value=f"path: {self.installed}"):
            with contextlib.redirect_stdout(io.StringIO()) as stdout:
                self.assertEqual(cr.main(["--quiet"]), 0)
        self.assertEqual(stdout.getvalue(), "")

    def test_success_unregisters_selected_build_and_reregisters_installs(self) -> None:
        after = "\n".join(f"path: {app}" for app in (self.other_build, self.installed, self.custom_installed))
        with mock.patch.object(cr, "registration_dump", side_effect=[self.dump, after]):
            with mock.patch.object(cr.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
                with contextlib.redirect_stdout(io.StringIO()) as stdout:
                    self.assertEqual(cr.main(["--scope", str(self.root / "build" / "test"), "--quiet"]), 0)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(["pluginkit", "-r", str(self.build / cr.APPEX)], commands)
        self.assertIn([str(cr.LSREGISTER), "-u", str(self.build)], commands)
        self.assertIn([str(cr.LSREGISTER), "-f", str(self.installed)], commands)
        self.assertIn([str(cr.LSREGISTER), "-f", str(self.custom_installed)], commands)
        self.assertNotIn([str(cr.LSREGISTER), "-u", str(self.other_build)], commands)
        self.assertIn(f"Unregistering {self.build}", stdout.getvalue())

    def test_partial_failure_warns_when_quiet_and_returns_nonzero(self) -> None:
        def run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            if command[:2] == ["pluginkit", "-r"]:
                return subprocess.CompletedProcess(command, 1, "", "pluginkit failed")
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(cr, "registration_dump", side_effect=[self.dump, self.dump]):
            with mock.patch.object(cr.subprocess, "run", side_effect=run):
                with contextlib.redirect_stderr(io.StringIO()) as stderr:
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(cr.main(["--quiet", "--scope", str(self.root / "build" / "test")]), 1)
        self.assertIn("pluginkit failed", stderr.getvalue())
        self.assertIn(f"Registration remains: {self.build}", stderr.getvalue())

    def test_reregistration_failure_returns_nonzero(self) -> None:
        def run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(command, 1 if command[1] == "-f" else 0, "", "refresh failed")

        after = f"path: {self.installed}"
        with mock.patch.object(cr, "registration_dump", side_effect=[self.dump, after]):
            with mock.patch.object(cr.subprocess, "run", side_effect=run):
                with contextlib.redirect_stderr(io.StringIO()) as stderr:
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(cr.main(["--scope", str(self.root / "build" / "test")]), 1)
        self.assertIn("refresh failed", stderr.getvalue())

    def test_all_dry_run_keeps_custom_installs(self) -> None:
        with mock.patch.object(cr, "registration_dump", return_value=self.dump):
            with contextlib.redirect_stdout(io.StringIO()) as stdout:
                self.assertEqual(cr.main(["--all", "--dry-run"]), 0)
        self.assertIn(f"Would unregister {self.build}", stdout.getvalue())
        self.assertIn(f"Would unregister {self.other_build}", stdout.getvalue())
        self.assertNotIn(str(self.custom_installed), stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
