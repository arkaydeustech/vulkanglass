from __future__ import annotations

import base64
import unittest
from pathlib import Path

from scripts import release

APPCAST = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>0.3.0</title>
      <sparkle:version>41</sparkle:version>
      <enclosure url="https://example.com/a.zip" sparkle:edSignature="sig" length="1"/>
    </item>
    <item>
      <title>0.2.9</title>
      <enclosure url="https://example.com/b.zip" sparkle:version="39" length="1"/>
    </item>
  </channel>
</rss>
"""

FIND_IDENTITY = """  1) CBFB428376A3CA4BD7F1BB611FDCE25FC58B04D4 "Developer ID Application: Example Ltd. (QWD87G9T3P)"
  2) 37E58DF8B070B0B01122C504837F9EC80ECEE57E "Apple Development: Someone (65B784YUJW)"
  3) AAAA428376A3CA4BD7F1BB611FDCE25FC58B04D4 "Developer ID Application: Other Co (ZZZZZZZZZZ)"
     3 valid identities found
"""


class VersionTests(unittest.TestCase):
    def test_reads_the_generator_version(self) -> None:
        self.assertEqual(
            release.read_marketing_version('ROOT = 1\nAPP_MARKETING_VERSION = "0.3.0"\n'),
            "0.3.0",
        )

    def test_rejects_missing_or_malformed_versions(self) -> None:
        for source in ("", 'APP_MARKETING_VERSION = "0.3-beta"\n', 'APP_MARKETING_VERSION = "1"\n'):
            with self.subTest(source=source), self.assertRaises(release.ReleaseError):
                release.read_marketing_version(source)

    def test_repository_sources_agree_on_the_version(self) -> None:
        root = Path(release.ROOT)
        version = release.read_marketing_version(
            (root / "scripts" / "generate_xcodeproj.py").read_text()
        )
        user_agent = release.read_user_agent_version(
            (root / "VulkanGlass" / "GitHubService.swift").read_text()
        )
        self.assertEqual(user_agent, version)

    def test_app_plist_takes_versions_from_build_settings(self) -> None:
        plist = (Path(release.ROOT) / "VulkanGlass" / "Info.plist").read_text()
        self.assertIn("<string>$(MARKETING_VERSION)</string>", plist)
        self.assertIn("<string>$(CURRENT_PROJECT_VERSION)</string>", plist)


class BuildNumberTests(unittest.TestCase):
    def test_reads_element_and_attribute_build_numbers(self) -> None:
        self.assertEqual(release.published_build_numbers(APPCAST), [41, 39])

    def test_uses_commit_count_when_newer_than_published(self) -> None:
        self.assertEqual(release.choose_build_number(42, 41), 42)
        self.assertEqual(release.choose_build_number(42, None), 42)

    def test_refuses_a_build_that_is_not_newer(self) -> None:
        with self.assertRaises(release.ReleaseError):
            release.choose_build_number(41, 41)

    def test_override_must_still_be_newer(self) -> None:
        self.assertEqual(release.choose_build_number(10, 41, override=50), 50)
        with self.assertRaises(release.ReleaseError):
            release.choose_build_number(100, 41, override=40)

    def test_never_reuses_the_development_build_number(self) -> None:
        with self.assertRaises(release.ReleaseError):
            release.choose_build_number(1, None)


class KeyAndIdentityTests(unittest.TestCase):
    def test_public_key_must_be_32_base64_bytes(self) -> None:
        self.assertTrue(release.is_valid_public_key(base64.b64encode(bytes(32)).decode()))
        self.assertFalse(release.is_valid_public_key(base64.b64encode(bytes(31)).decode()))
        self.assertFalse(release.is_valid_public_key("not base64!"))
        self.assertFalse(release.is_valid_public_key(""))

    def test_selects_the_developer_id_for_the_release_team(self) -> None:
        self.assertEqual(
            release.find_signing_identity(FIND_IDENTITY, "QWD87G9T3P"),
            "CBFB428376A3CA4BD7F1BB611FDCE25FC58B04D4",
        )
        self.assertIsNone(release.find_signing_identity(FIND_IDENTITY, "65B784YUJW"))

    def test_export_uses_developer_id_distribution(self) -> None:
        options = release.export_options("QWD87G9T3P")
        self.assertEqual(options["method"], "developer-id")
        self.assertEqual(options["teamID"], "QWD87G9T3P")

    def test_feed_is_the_public_latest_release_appcast(self) -> None:
        self.assertEqual(
            release.FEED_URL,
            "https://github.com/arkaydeustech/vulkanglass/releases/latest/download/appcast.xml",
        )

    def test_committed_public_key_is_unset_or_valid(self) -> None:
        key = release.SPARKLE_PUBLIC_ED_KEY
        self.assertTrue(key == "" or release.is_valid_public_key(key))


class ReleaseNotesTests(unittest.TestCase):
    def test_first_release_is_summarised(self) -> None:
        notes = release.release_notes("0.3.0", None)
        self.assertEqual(notes, "## Vulkan Glass 0.3.0\n\nThe first public release of Vulkan Glass.\n")

    def test_lists_user_facing_changes_only(self) -> None:
        notes = release.release_notes(
            "0.3.1",
            [
                "fix(editor): keep the caret after paste (#4)",
                "feat: add a graph filter (#3)",
                "chore: bump version",
                "docs(updates): explain releases",
                "Merge something by hand",
            ],
        )
        self.assertEqual(
            notes,
            "## Vulkan Glass 0.3.1\n\n"
            "- Keep the caret after paste (#4)\n"
            "- Add a graph filter (#3)\n"
            "- Merge something by hand\n",
        )

    def test_internal_only_releases_say_so(self) -> None:
        notes = release.release_notes("0.3.2", ["chore: tidy", "ci: faster"])
        self.assertTrue(notes.endswith("Maintenance and internal improvements.\n"))


if __name__ == "__main__":
    unittest.main()
