from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / ".oxlintrc.json"

VALID_SOURCE = "const value = 1;\nconsole.log(value);\n"
INVALID_SOURCE = "const value = 1;\nvalue = 2;\nconsole.log(value);\n"


class OxlintConfigurationTestCase(unittest.TestCase):
    def run_oxlint(self, source: str) -> subprocess.CompletedProcess[str]:
        self.assertTrue(
            shutil.which("oxlint"),
            "oxlint not found; run this test through `mise run test:lint`",
        )
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "sample.js"
            target.write_text(source)
            return subprocess.run(
                [
                    "oxlint",
                    "--config",
                    str(CONFIG),
                    "--no-error-on-unmatched-pattern",
                    str(target),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )

    def test_valid_source_passes(self) -> None:
        result = self.run_oxlint(VALID_SOURCE)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_correctness_violation_fails(self) -> None:
        result = self.run_oxlint(INVALID_SOURCE)
        self.assertNotEqual(result.returncode, 0, "oxlint did not flag a known violation")
        self.assertIn("no-const-assign", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
