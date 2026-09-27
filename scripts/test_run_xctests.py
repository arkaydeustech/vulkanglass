from __future__ import annotations

import contextlib
import io
import subprocess
import unittest
from unittest import mock

from scripts import run_xctests


class RunXCTestsTests(unittest.TestCase):
    def test_failure_still_cleans_only_test_build_and_preserves_status(self) -> None:
        with mock.patch.object(run_xctests.subprocess, "run", return_value=subprocess.CompletedProcess([], 65)) as run:
            with mock.patch.object(run_xctests.clean_registrations, "main", return_value=0) as clean:
                self.assertEqual(run_xctests.main(["-only-testing:MissingTest"]), 65)
        command = run.call_args.args[0]
        self.assertEqual(command[-1], "-only-testing:MissingTest")
        self.assertEqual(command[command.index("-derivedDataPath") + 1], "build/test")
        self.assertEqual(clean.call_args.args[0], [
            "--quiet", "--scope", str(run_xctests.clean_registrations.ROOT / "build" / "test")
        ])

    def test_cleanup_failure_is_reported_without_overriding_xcodebuild_status(self) -> None:
        with mock.patch.object(run_xctests.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            with mock.patch.object(run_xctests.clean_registrations, "main", return_value=1):
                with contextlib.redirect_stderr(io.StringIO()) as stderr:
                    self.assertEqual(run_xctests.main([]), 0)
        self.assertIn("cleanup was incomplete", stderr.getvalue())

    def test_cleanup_runs_when_xcodebuild_cannot_start(self) -> None:
        with mock.patch.object(run_xctests.subprocess, "run", side_effect=OSError("missing xcodebuild")):
            with mock.patch.object(run_xctests.clean_registrations, "main", return_value=0) as clean:
                with self.assertRaisesRegex(OSError, "missing xcodebuild"):
                    run_xctests.main([])
        clean.assert_called_once()


if __name__ == "__main__":
    unittest.main()
