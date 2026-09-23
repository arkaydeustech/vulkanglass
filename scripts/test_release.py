from __future__ import annotations

import base64
import argparse
import contextlib
import io
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError, URLError

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
        self.assertNotIn("provisioningProfiles", options)

    def test_feed_is_the_public_latest_release_appcast(self) -> None:
        self.assertEqual(
            release.FEED_URL,
            "https://github.com/arkaydeustech/vulkanglass/releases/latest/download/appcast.xml",
        )

    def test_committed_public_key_is_the_release_key(self) -> None:
        # Every installed release trusts this key; changing it breaks updates.
        self.assertEqual(
            release.SPARKLE_PUBLIC_ED_KEY, "SFrWmZbsFPcOp0DLhXi0inL1895NkukUehmnXjIez9E="
        )
        self.assertTrue(release.is_valid_public_key(release.SPARKLE_PUBLIC_ED_KEY))


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


class FeedTests(unittest.TestCase):
    def test_reads_newest_build_from_published_feed(self) -> None:
        with mock.patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(APPCAST.encode())):
            self.assertEqual(release.latest_published_build(), 41)

    def test_feed_404_is_only_first_release_when_github_has_no_release(self) -> None:
        missing = HTTPError(release.FEED_URL, 404, "Not Found", {}, io.BytesIO())
        with mock.patch.object(release.urllib.request, "urlopen", side_effect=[missing, io.BytesIO(b"[]")]):
            self.assertIsNone(release.latest_published_build())
        missing.close()
        missing = HTTPError(release.FEED_URL, 404, "Not Found", {}, io.BytesIO())
        with mock.patch.object(
            release.urllib.request, "urlopen", side_effect=[missing, io.BytesIO(b'[{"draft": false}]')]
        ):
            with self.assertRaisesRegex(release.ReleaseError, "appcast is missing"):
                release.latest_published_build()
        missing.close()

    def test_feed_errors_and_malformed_content_fail_closed(self) -> None:
        for problem in (URLError("offline"), io.BytesIO(b"<rss>"), io.BytesIO(b"<rss/>")):
            with self.subTest(problem=problem), mock.patch.object(
                release.urllib.request, "urlopen", side_effect=problem if isinstance(problem, URLError) else None,
                return_value=None if isinstance(problem, URLError) else problem,
            ):
                with self.assertRaises(release.ReleaseError):
                    release.latest_published_build()

    def test_prior_release_api_failure_does_not_imply_first_release(self) -> None:
        missing = HTTPError(release.FEED_URL, 404, "Not Found", {}, io.BytesIO())
        with mock.patch.object(release.urllib.request, "urlopen", side_effect=[missing, URLError("offline")]):
            with self.assertRaisesRegex(release.ReleaseError, "prior GitHub releases"):
                release.latest_published_build()
        missing.close()


class GitStateTests(unittest.TestCase):
    def test_clean_main_matching_origin_returns_sha(self) -> None:
        answers = {
            ("rev-parse", "HEAD"): "first-sha",
            ("status", "--porcelain"): "",
            ("rev-parse", "--abbrev-ref", "HEAD"): "main",
            ("fetch", "--quiet", "origin", "main"): "",
            ("rev-parse", "origin/main"): "first-sha",
            ("tag", "--list", "v1.2.3"): "",
            ("ls-remote", "--tags", "origin", "refs/tags/v1.2.3"): "",
        }
        with mock.patch.object(release, "git", side_effect=lambda *args: answers[args]):
            self.assertEqual(release.check_git_state("1.2.3", "v1.2.3", True), "first-sha")
            for changed, value in (
                (("status", "--porcelain"), " M file"),
                (("rev-parse", "--abbrev-ref", "HEAD"), "topic"),
                (("rev-parse", "origin/main"), "another-sha"),
                (("tag", "--list", "v1.2.3"), "v1.2.3"),
                (("ls-remote", "--tags", "origin", "refs/tags/v1.2.3"), "remote-sha"),
            ):
                with self.subTest(changed=changed):
                    original = answers[changed]
                    answers[changed] = value
                    with self.assertRaises(release.ReleaseError):
                        release.check_git_state("1.2.3", "v1.2.3", True)
                    with contextlib.redirect_stdout(io.StringIO()) as stdout:
                        release.check_git_state("1.2.3", "v1.2.3", False)
                    self.assertIn("warning:", stdout.getvalue())
                    answers[changed] = original


def sample_release(source_sha: str = "source-sha") -> release.Release:
    return release.Release(
        "1.2.3", "v1.2.3", 42, "identity", "Release notes\n", source_sha,
    )


class PipelineTests(unittest.TestCase):
    def test_prepare_checks_prerequisites_and_captures_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            release, "DEVELOPER_DIR", Path(temporary)
        ), mock.patch.object(release, "run") as run, mock.patch.object(
            release, "read_versions", return_value=("1.2.3", "v1.2.3")
        ), mock.patch.object(release, "check_git_state", return_value="built-sha") as git_state, mock.patch.object(
            release, "check_github"
        ) as github, mock.patch.object(release, "signing_identity", return_value="identity"), mock.patch.object(
            release, "check_notary_profile"
        ) as notary, mock.patch.object(
            release, "resolve_packages"
        ) as packages, mock.patch.object(release, "check_sparkle_key") as sparkle, mock.patch.object(
            release, "latest_published_build", return_value=41
        ), mock.patch.object(release, "git", return_value="42"), mock.patch.object(
            release, "previous_release_subjects", return_value=["fix: repair"]
        ):
            prepared = release.prepare(argparse.Namespace(), publishing=True)
        self.assertEqual(prepared.source_sha, "built-sha")
        self.assertEqual(prepared.build_number, 42)
        self.assertIn("Repair", prepared.notes)
        run.assert_called_once()
        git_state.assert_called_once_with("1.2.3", "v1.2.3", True)
        for check in (github, notary, packages, sparkle):
            check.assert_called_once()

    def test_check_reports_every_prerequisite_instead_of_stopping(self) -> None:
        not_main = release.ReleaseError("HEAD is not the main branch")
        no_key = release.ReleaseError("SPARKLE_PUBLIC_ED_KEY is not set")
        printed = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            release, "DEVELOPER_DIR", Path(temporary)
        ), mock.patch.object(release, "run"), mock.patch.object(
            release, "read_versions", return_value=("1.2.3", "v1.2.3")
        ), mock.patch.object(release, "check_git_state", side_effect=not_main), mock.patch.object(
            release, "check_github"
        ), mock.patch.object(release, "signing_identity", return_value="identity"), mock.patch.object(
            release, "check_notary_profile"
        ) as notary, mock.patch.object(release, "resolve_packages"), mock.patch.object(
            release, "check_sparkle_key", side_effect=no_key
        ), mock.patch.object(release, "latest_published_build", return_value=None), mock.patch.object(
            release, "git", return_value="42"
        ), contextlib.redirect_stdout(printed):
            with self.assertRaisesRegex(release.ReleaseError, "2 of 8 prerequisites"):
                release.check()
        notary.assert_called_once()
        report = printed.getvalue()
        self.assertIn("✓ Notarization credentials", report)
        self.assertIn("✗ Sparkle signing key", report)
        self.assertIn("HEAD is not the main branch", report)

    def test_archive_export_uses_developer_id_options(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(release, "WORK", Path(temporary)):
            prepared = sample_release()
            prepared.directory.joinpath("build").mkdir(parents=True)
            commands = []

            def fake_run(command: list[str]) -> None:
                commands.append(command)
                if "-exportArchive" in command:
                    (prepared.directory / "build" / "export" / release.APP_NAME).mkdir(parents=True)

            with mock.patch.object(release, "run", side_effect=fake_run):
                app = release.archive_and_export(prepared)
            self.assertTrue(app.is_dir())
            options = plistlib.loads((prepared.directory / "build" / "ExportOptions.plist").read_bytes())
            self.assertEqual(options["method"], "developer-id")
            self.assertEqual(options["signingStyle"], "manual")
            self.assertNotIn("provisioningProfiles", options)

    def test_verify_app_checks_plists_and_signature(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / release.APP_NAME
            extension = app / "Contents" / "PlugIns" / release.QUICK_LOOK_NAME / "Contents"
            extension.mkdir(parents=True)
            info = {
                "CFBundleIdentifier": release.BUNDLE_ID,
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "42",
                "SUFeedURL": release.FEED_URL,
                "SUPublicEDKey": release.SPARKLE_PUBLIC_ED_KEY,
            }
            (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
            extension_info = {**info, "CFBundleIdentifier": release.QUICK_LOOK_BUNDLE_ID}
            (extension / "Info.plist").write_bytes(plistlib.dumps(extension_info))
            signature = subprocess.CompletedProcess([], 0, "", f"TeamIdentifier={release.TEAM_ID} (runtime) Timestamp=now")
            signed_entitlements = {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.files.user-selected.read-only": True,
            }

            def codesign_output(command: list[str]) -> subprocess.CompletedProcess[str]:
                if "--entitlements" in command:
                    return subprocess.CompletedProcess(command, 0, plistlib.dumps(signed_entitlements).decode(), "")
                return signature

            with mock.patch.object(release, "run") as run, mock.patch.object(release, "output", side_effect=codesign_output):
                release.verify_app(app, sample_release())
                self.assertEqual(run.call_count, 2)
            del signed_entitlements["com.apple.security.app-sandbox"]
            with mock.patch.object(release, "run"), mock.patch.object(release, "output", side_effect=codesign_output):
                with self.assertRaisesRegex(release.ReleaseError, "app-sandbox"):
                    release.verify_app(app, sample_release())
            extension_info["CFBundleVersion"] = "41"
            (extension / "Info.plist").write_bytes(plistlib.dumps(extension_info))
            with self.assertRaisesRegex(release.ReleaseError, "Quick Look extension"):
                release.verify_app(app, sample_release())

    def test_generated_appcast_validates_build_url_and_signature(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(release, "WORK", Path(temporary)):
            prepared = sample_release()
            prepared.directory.mkdir()
            prefix = f"https://github.com/{release.REPOSITORY}/releases/download/{prepared.tag}/"
            def archive_xml(build: str, url: str, signature: str) -> str:
                return (
                    f'<rss xmlns:sparkle="{release.SPARKLE_NS}"><channel><item>'
                    f'<sparkle:version>{build}</sparkle:version>'
                    f'<enclosure url="{url}" sparkle:edSignature="{signature}" />'
                    "</item></channel></rss>"
                )
            cases = [
                ("42", prefix + prepared.zip_name, "sig", None),
                ("41", prefix + prepared.zip_name, "sig", "exactly this build"),
                ("42", "https://example.com/wrong.zip", "sig", "unexpected download URL"),
                ("42", prefix + prepared.zip_name, "", "not EdDSA-signed"),
            ]
            for build, url, signature, error in cases:
                with self.subTest(error=error):
                    updates = prepared.directory / "updates"
                    if updates.exists():
                        shutil.rmtree(updates)

                    def fake_run(command: list[str]) -> None:
                        if "generate_appcast" in command[0]:
                            (updates / "appcast.xml").write_text(archive_xml(build, url, signature))

                    with mock.patch.object(release, "run", side_effect=fake_run):
                        if error:
                            with self.assertRaisesRegex(release.ReleaseError, error):
                                release.make_update_feed(Path(temporary) / "App", prepared)
                        else:
                            archive, appcast = release.make_update_feed(Path(temporary) / "App", prepared)
                            self.assertEqual(archive.name, prepared.zip_name)
                            self.assertTrue(appcast.is_file())

    def test_build_runs_full_pipeline_and_writes_notes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(release, "WORK", Path(temporary)):
            prepared = sample_release()
            app = Path(temporary) / "exported.app"
            dmg = Path(temporary) / "out.dmg"
            archive = Path(temporary) / "out.zip"
            feed = Path(temporary) / "appcast.xml"
            calls = []

            def record(name: str, value: object = None):
                def invoke(*args):
                    calls.append(name)
                    return value
                return invoke

            with mock.patch.object(release, "archive_and_export", side_effect=record("archive", app)), mock.patch.object(
                release, "verify_app", side_effect=record("verify")
            ), mock.patch.object(release, "notarize_app", side_effect=record("notarize")), mock.patch.object(
                release, "make_dmg", side_effect=record("dmg", dmg)
            ), mock.patch.object(release, "make_update_feed", side_effect=record("feed", (archive, feed))):
                assets = release.build(prepared)
            self.assertEqual(calls, ["archive", "verify", "notarize", "dmg", "feed"])
            self.assertEqual(assets, [dmg, archive, feed])
            self.assertEqual((prepared.directory / "release-notes.md").read_text(), prepared.notes)

    def test_notarization_requires_accepted_status(self) -> None:
        accepted = subprocess.CompletedProcess([], 0, '{"status":"Accepted"}', "")
        rejected = subprocess.CompletedProcess([], 0, '{"status":"Invalid"}', "")
        with mock.patch.object(release, "output", return_value=accepted):
            release.notarize(Path("example.zip"))
        with mock.patch.object(release, "output", return_value=rejected):
            with self.assertRaisesRegex(release.ReleaseError, "Notarization of example.zip failed"):
                release.notarize(Path("example.zip"))

    def test_publish_keeps_draft_when_asset_is_missing(self) -> None:
        prepared = sample_release()
        assets = [Path("VulkanGlass.dmg"), Path(prepared.zip_name), Path("appcast.xml")]
        uploaded = subprocess.CompletedProcess([], 0, "VulkanGlass.dmg\nappcast.xml\n", "")
        with mock.patch.object(release, "check_git_state", return_value=prepared.source_sha), mock.patch.object(
            release, "run"
        ) as run, mock.patch.object(release, "output", return_value=uploaded):
            with self.assertRaisesRegex(release.ReleaseError, "left unpublished"):
                release.publish(prepared, assets)
        self.assertFalse(any("--draft=false" in call.args[0] for call in run.call_args_list))

    def test_publish_reports_success_after_public_feed_read_failure(self) -> None:
        prepared = sample_release()
        assets = [Path("VulkanGlass.dmg"), Path(prepared.zip_name), Path("appcast.xml")]
        uploaded = subprocess.CompletedProcess([], 0, "VulkanGlass.dmg\n" + prepared.zip_name + "\nappcast.xml\n", "")
        with mock.patch.object(release, "check_git_state", return_value=prepared.source_sha), mock.patch.object(
            release, "run"
        ) as run, mock.patch.object(release, "output", return_value=uploaded), mock.patch.object(
            release, "latest_published_build", side_effect=release.ReleaseError("network unavailable")
        ), contextlib.redirect_stdout(io.StringIO()) as stdout:
            release.publish(prepared, assets)
        self.assertTrue(any("--draft=false" in call.args[0] for call in run.call_args_list))
        self.assertIn("release is already public", stdout.getvalue())
        self.assertIn("Published https://", stdout.getvalue())

    def test_main_converts_missing_tool_or_notes_file_to_release_error(self) -> None:
        for missing in ("gh", "/nonexistent/notes.md"):
            with self.subTest(missing=missing), mock.patch.object(
                release, "parse_args", return_value=argparse.Namespace(command="publish")
            ), mock.patch.object(release, "prepare", side_effect=FileNotFoundError(2, "No such file or directory", missing)):
                with self.assertRaises(SystemExit) as caught:
                    release.main()
                self.assertIn(f"release: [Errno 2]", str(caught.exception))
                self.assertIn(missing, str(caught.exception))


class PublishGitTests(unittest.TestCase):
    def test_changed_commit_aborts_and_tag_targets_saved_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            origin = root / "origin.git"
            checkout = root / "checkout"
            subprocess.run(["git", "init", "--bare", str(origin)], check=True, capture_output=True)
            subprocess.run(["git", "init", "-b", "main", str(checkout)], check=True, capture_output=True)
            def command(*args: str) -> str:
                return subprocess.run(["git", *args], cwd=checkout, check=True, capture_output=True, text=True).stdout.strip()

            command("config", "user.name", "Release Test")
            command("config", "user.email", "release-test@example.invalid")
            command("remote", "add", "origin", str(origin))
            (checkout / "source.txt").write_text("first\n")
            command("add", "source.txt")
            command("commit", "-m", "first")
            command("push", "-u", "origin", "main")
            saved_sha = command("rev-parse", "HEAD")
            (checkout / "source.txt").write_text("second\n")
            command("commit", "-am", "second")
            command("push", "origin", "main")
            current_sha = command("rev-parse", "HEAD")
            assets = [Path("VulkanGlass.dmg"), Path("VulkanGlass-1.2.3.zip"), Path("appcast.xml")]
            real_run = release.run
            real_output = release.output

            def fake_run(args: list[str]) -> None:
                if args[0] == "git":
                    real_run(args)

            def fake_output(args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
                if args[0] == "gh":
                    return subprocess.CompletedProcess(args, 0, "\n".join(item.name for item in assets), "")
                return real_output(args, check)

            with mock.patch.object(release, "ROOT", checkout), mock.patch.object(
                release, "run", side_effect=fake_run
            ), mock.patch.object(release, "output", side_effect=fake_output), mock.patch.object(
                release, "latest_published_build", return_value=42
            ):
                with self.assertRaisesRegex(release.ReleaseError, "HEAD moved"):
                    release.publish(sample_release(saved_sha), assets)
                self.assertEqual(command("tag", "--list", "v1.2.3"), "")
                release.publish(sample_release(current_sha), assets)
            self.assertEqual(command("rev-list", "-n", "1", "v1.2.3"), current_sha)
            self.assertEqual(
                subprocess.run(["git", "--git-dir", str(origin), "rev-list", "-n", "1", "v1.2.3"], check=True, capture_output=True, text=True).stdout.strip(),
                current_sha,
            )

if __name__ == "__main__":
    unittest.main()
