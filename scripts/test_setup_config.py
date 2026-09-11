from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "orkestrator-ai.json"
PHASES = ("root", "setupContainer", "setupLocal", "run")


class SetupConfigTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.data = json.loads(CONFIG.read_text())

    def commands(self):
        for phase in PHASES:
            self.assertIn(phase, self.data)
            self.assertIsInstance(self.data[phase], list, phase)
            for command in self.data[phase]:
                yield phase, command

    def test_no_remote_content_is_piped_to_a_shell(self) -> None:
        for phase, command in self.commands():
            for forbidden in ("curl", "wget", "| sh", "|sh", "mise.run"):
                self.assertNotIn(forbidden, command, f"{phase}: {command}")

    def test_provisioning_runs_repository_local_python(self) -> None:
        for phase in ("setupContainer", "setupLocal", "run"):
            for command in self.data[phase]:
                self.assertIn("python3", command, f"{phase}: {command}")

    def test_root_package_step_is_idempotent(self) -> None:
        self.assertIn("command -v python3", " ".join(self.data["root"]))


if __name__ == "__main__":
    unittest.main()
