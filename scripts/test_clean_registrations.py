from __future__ import annotations

import unittest
from pathlib import Path

from scripts import clean_registrations as cr

DUMP = """\
bundle id:                  1234
path:                       /Applications/VulkanGlass.app (0x1a2b)
path:                       /Applications/VulkanGlass.app/Contents/PlugIns/VulkanGlassQuickLook.appex (0x1a2c)
path:                       /Users/me/work/vg/build/test/Build/Products/Debug/VulkanGlass.app (0x3c4d)
path:                       /Users/me/work/vg/build/test/Build/Products/Debug/VulkanGlass.app (0x3c4e)
path:                       /private/tmp/vg-dd/Build/Products/Debug/VulkanGlass.app (0x5e6f)
path:                       /Applications/Other.app (0x7a8b)
"""


class RegisteredAppsTests(unittest.TestCase):
    def test_parses_and_deduplicates_app_paths(self) -> None:
        self.assertEqual(
            cr.registered_apps(DUMP),
            [
                Path("/Applications/VulkanGlass.app"),
                Path("/Users/me/work/vg/build/test/Build/Products/Debug/VulkanGlass.app"),
                Path("/private/tmp/vg-dd/Build/Products/Debug/VulkanGlass.app"),
            ],
        )


class SelectTests(unittest.TestCase):
    def setUp(self) -> None:
        self.apps = cr.registered_apps(DUMP)

    def test_scope_limits_to_checkout_and_keeps_installed_app(self) -> None:
        self.assertEqual(
            cr.select(self.apps, Path("/Users/me/work/vg")),
            [Path("/Users/me/work/vg/build/test/Build/Products/Debug/VulkanGlass.app")],
        )

    def test_all_includes_strays_but_never_the_installed_app(self) -> None:
        selected = cr.select(self.apps, None)
        self.assertNotIn(cr.INSTALLED, selected)
        self.assertIn(Path("/private/tmp/vg-dd/Build/Products/Debug/VulkanGlass.app"), selected)


if __name__ == "__main__":
    unittest.main()
