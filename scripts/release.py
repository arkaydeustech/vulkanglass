#!/usr/bin/env python3
"""Build, notarize, and publish a Vulkan Glass release from this Mac.

Subcommands:
  setup    one-time: create or look up the Sparkle update signing key and
           check the other release prerequisites
  check    verify every prerequisite for publishing, without building
  build    build, notarize, and package a release without publishing it
  publish  build, then tag the commit and publish the GitHub release

Signing, notarization, and the Sparkle key all stay in the login Keychain.
See docs/app-updates.md.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")
WORK = ROOT / "output" / "release"
PACKAGES = WORK / "SourcePackages"
SPARKLE_BIN = PACKAGES / "artifacts" / "sparkle" / "Sparkle" / "bin"

REPOSITORY = "arkaydeustech/vulkanglass"
TEAM_ID = "QWD87G9T3P"
NOTARY_PROFILE = "vulkanglass-notary"
BUNDLE_ID = "app.vulkanglass.desktop"
APP_NAME = "VulkanGlass.app"
QUICK_LOOK_NAME = "VulkanGlassQuickLook.appex"
QUICK_LOOK_BUNDLE_ID = f"{BUNDLE_ID}.quicklook"
DMG_NAME = "VulkanGlass.dmg"
VOLUME_NAME = "Vulkan Glass"

# Public values embedded in every release. The matching private key lives only
# in the release maintainer's login Keychain (see `release.py setup`). Every
# published app trusts this key, so never change it without a migration plan.
SPARKLE_PUBLIC_ED_KEY = ""
FEED_URL = f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml"

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
USER_FACING_TYPES = {"feat", "fix", "perf"}
CONVENTIONAL_SUBJECT = re.compile(r"^(?P<type>[a-z]+)(\([^)]*\))?!?:\s*(?P<text>.+)$")


class ReleaseError(Exception):
    """A release prerequisite or step failed; the message says what to do."""


@dataclass
class Release:
    version: str
    tag: str
    build_number: int
    identity: str
    notes: str
    source_sha: str

    @property
    def directory(self) -> Path:
        return WORK / self.tag

    @property
    def zip_name(self) -> str:
        return f"VulkanGlass-{self.version}.zip"


# Pure helpers (unit tested in scripts/test_release.py)


def read_marketing_version(generator_source: str) -> str:
    match = re.search(r'^APP_MARKETING_VERSION = "([^"]+)"$', generator_source, re.M)
    if not match:
        raise ReleaseError("APP_MARKETING_VERSION not found in scripts/generate_xcodeproj.py")
    version = match.group(1)
    if not re.fullmatch(r"\d+(\.\d+){1,2}", version):
        raise ReleaseError(f"Version {version!r} must look like 1.2 or 1.2.3")
    return version


def read_user_agent_version(service_source: str) -> str | None:
    match = re.search(r'"VulkanGlass/([^"]+)"', service_source)
    return match.group(1) if match else None


def is_valid_public_key(key: str) -> bool:
    try:
        return len(base64.b64decode(key, validate=True)) == 32
    except (binascii.Error, ValueError):
        return False


def published_build_numbers(appcast_xml: str) -> list[int]:
    numbers: list[int] = []
    for item in ET.fromstring(appcast_xml).iter("item"):
        version = item.findtext(f"{{{SPARKLE_NS}}}version")
        enclosure = item.find("enclosure")
        if version is None and enclosure is not None:
            version = enclosure.get(f"{{{SPARKLE_NS}}}version")
        if version and version.strip().isdigit():
            numbers.append(int(version.strip()))
    return numbers


def choose_build_number(
    commit_count: int, latest_published: int | None, override: int | None = None
) -> int:
    number = commit_count if override is None else override
    if number < 2:
        raise ReleaseError("The build number must be at least 2; development builds use 1.")
    if latest_published is not None and number <= latest_published:
        raise ReleaseError(
            f"Build number {number} is not newer than the published build "
            f"{latest_published}. Pass --build-number with a larger value."
        )
    return number


def find_signing_identity(find_identity_output: str, team_id: str) -> str | None:
    """Return the SHA-1 of the team's Developer ID Application certificate."""
    pattern = re.compile(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"Developer ID Application: .* \((\w+)\)"$')
    for line in find_identity_output.splitlines():
        match = pattern.match(line)
        if match and match.group(2) == team_id:
            return match.group(1)
    return None


def release_notes(version: str, subjects: list[str] | None) -> str:
    """Markdown notes from commit subjects since the previous release.

    `subjects` is None for the first release, whose history predates the public
    repository and is summarised instead of listed.
    """
    lines = [f"## Vulkan Glass {version}", ""]
    if subjects is None:
        lines.append("The first public release of Vulkan Glass.")
        return "\n".join(lines) + "\n"

    entries = []
    for subject in subjects:
        match = CONVENTIONAL_SUBJECT.match(subject)
        if match is None:
            entries.append(subject)
        elif match.group("type") in USER_FACING_TYPES:
            text = match.group("text")
            entries.append(text[:1].upper() + text[1:])
    lines.extend(f"- {entry}" for entry in entries)
    if not entries:
        lines.append("Maintenance and internal improvements.")
    return "\n".join(lines) + "\n"


def export_options(team_id: str) -> dict[str, str]:
    return {
        "destination": "export",
        "method": "developer-id",
        "signingCertificate": "Developer ID Application",
        "signingStyle": "manual",
        "teamID": team_id,
    }


# Process helpers


def xcode_env() -> dict[str, str]:
    return {**os.environ, "DEVELOPER_DIR": str(DEVELOPER_DIR)}


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.check_call(cmd, cwd=ROOT, env=xcode_env())


def output(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(cmd, cwd=ROOT, env=xcode_env(), capture_output=True, text=True)
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise ReleaseError(f"{' '.join(cmd)} failed: {detail}")
    return result


def git(*args: str) -> str:
    return output(["git", *args]).stdout.strip()


def step(message: str) -> None:
    print(f"\n==> {message}", flush=True)


# Prerequisites


def resolve_packages() -> None:
    run(
        [
            "xcodebuild",
            "-resolvePackageDependencies",
            "-project",
            "VulkanGlass.xcodeproj",
            "-scheme",
            "VulkanGlass",
            "-clonedSourcePackagesDirPath",
            str(PACKAGES),
        ]
    )
    if not (SPARKLE_BIN / "generate_appcast").is_file():
        raise ReleaseError(f"Sparkle tools not found in {SPARKLE_BIN}")


def keychain_public_key() -> str | None:
    result = output([str(SPARKLE_BIN / "generate_keys"), "-p"], check=False)
    key = result.stdout.strip()
    return key if result.returncode == 0 and is_valid_public_key(key) else None


def check_sparkle_key() -> None:
    if not is_valid_public_key(SPARKLE_PUBLIC_ED_KEY):
        raise ReleaseError(
            "SPARKLE_PUBLIC_ED_KEY is not set in scripts/release.py. "
            "Run `mise run release:setup` first."
        )
    key = keychain_public_key()
    if key is None:
        raise ReleaseError(
            "No Sparkle signing key found in the login Keychain. Import the backup "
            f"with `{SPARKLE_BIN / 'generate_keys'} -f <file>`."
        )
    if key != SPARKLE_PUBLIC_ED_KEY:
        raise ReleaseError(
            "The Keychain's Sparkle key does not match SPARKLE_PUBLIC_ED_KEY; "
            "installed apps would reject this update."
        )


def signing_identity() -> str:
    found = output(["security", "find-identity", "-v", "-p", "codesigning"]).stdout
    identity = find_signing_identity(found, TEAM_ID)
    if identity is None:
        raise ReleaseError(
            f"No valid 'Developer ID Application' certificate for team {TEAM_ID} "
            "in the login Keychain."
        )
    return identity


def check_notary_profile() -> None:
    result = output(
        ["xcrun", "notarytool", "history", "--keychain-profile", NOTARY_PROFILE],
        check=False,
    )
    if result.returncode != 0:
        raise ReleaseError(
            f"Notarization credentials '{NOTARY_PROFILE}' are missing or invalid. Store "
            f"them with: xcrun notarytool store-credentials {NOTARY_PROFILE} "
            f"--apple-id <your Apple ID> --team-id {TEAM_ID}"
        )


def check_github() -> None:
    origin = git("remote", "get-url", "origin")
    if REPOSITORY not in origin:
        raise ReleaseError(f"origin is {origin}, expected the {REPOSITORY} repository")
    result = output(
        ["gh", "api", f"repos/{REPOSITORY}", "--jq", ".permissions.push"], check=False
    )
    if result.stdout.strip() != "true":
        raise ReleaseError(f"The GitHub CLI cannot push to {REPOSITORY}. Run `gh auth login`.")


def check_git_state(version: str, tag: str, publishing: bool) -> str:
    problems = []
    head = git("rev-parse", "HEAD")
    if git("status", "--porcelain"):
        problems.append("the working tree has uncommitted changes")
    if git("rev-parse", "--abbrev-ref", "HEAD") != "main":
        problems.append("HEAD is not the main branch")
    else:
        git("fetch", "--quiet", "origin", "main")
        if head != git("rev-parse", "origin/main"):
            problems.append("main is not identical to origin/main")
    if git("tag", "--list", tag) or git("ls-remote", "--tags", "origin", f"refs/tags/{tag}"):
        problems.append(
            f"tag {tag} already exists; bump the version (docs/version-update.md)"
        )
    if not problems:
        return head
    message = "; ".join(problems)
    if publishing:
        raise ReleaseError(f"Cannot publish {version}: {message}.")
    print(f"warning: this build could not be published as-is: {message}.")
    return head


def read_versions() -> tuple[str, str]:
    generator = (ROOT / "scripts" / "generate_xcodeproj.py").read_text()
    version = read_marketing_version(generator)
    service = (ROOT / "VulkanGlass" / "GitHubService.swift").read_text()
    user_agent = read_user_agent_version(service)
    if user_agent != version:
        raise ReleaseError(
            f"GitHubService.swift sends VulkanGlass/{user_agent} but the app version is "
            f"{version}. Follow docs/version-update.md."
        )
    return version, f"v{version}"


def latest_published_build() -> int | None:
    try:
        with urllib.request.urlopen(FEED_URL, timeout=30) as response:
            numbers = published_build_numbers(response.read().decode())
    except urllib.error.HTTPError as error:
        if error.code == 404:
            if published_release_exists():
                raise ReleaseError(
                    "The published appcast is missing although a GitHub release exists; "
                    "cannot verify the previous build number."
                ) from error
            return None
        raise ReleaseError(f"Could not read the published appcast: {error}") from error
    except urllib.error.URLError as error:
        raise ReleaseError(f"Could not read the published appcast: {error}") from error
    except (ET.ParseError, UnicodeError) as error:
        raise ReleaseError(f"The published appcast is invalid: {error}") from error
    if not numbers:
        raise ReleaseError("The published appcast has no valid build number")
    return max(numbers)


def published_release_exists() -> bool:
    request = urllib.request.Request(
        f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=1",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "VulkanGlass-release"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            releases = json.load(response)
    except (urllib.error.HTTPError, urllib.error.URLError, ValueError) as error:
        raise ReleaseError(f"Could not check prior GitHub releases: {error}") from error
    if not isinstance(releases, list):
        raise ReleaseError("Could not check prior GitHub releases: unexpected API response")
    return any(not item.get("draft", False) for item in releases if isinstance(item, dict))


def previous_release_subjects() -> list[str] | None:
    result = output(
        ["git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD"],
        check=False,
    )
    if result.returncode != 0:
        return None
    log = git("log", "--format=%s", f"{result.stdout.strip()}..HEAD")
    return [line for line in log.splitlines() if line]


def prepare(args: argparse.Namespace, publishing: bool) -> Release:
    if not DEVELOPER_DIR.exists():
        raise ReleaseError("Xcode.app not found at /Applications/Xcode.app")
    step("Checking release prerequisites")
    run([sys.executable, str(ROOT / "scripts" / "generate_xcodeproj.py")])
    version, tag = read_versions()
    source_sha = check_git_state(version, tag, publishing)
    if publishing:
        check_github()
    identity = signing_identity()
    check_notary_profile()
    resolve_packages()
    check_sparkle_key()

    build_number = choose_build_number(
        int(git("rev-list", "--count", "HEAD")),
        latest_published_build(),
        getattr(args, "build_number", None),
    )
    notes_file = getattr(args, "notes", None)
    notes = (
        Path(notes_file).read_text()
        if notes_file
        else release_notes(version, previous_release_subjects())
    )
    print(f"Release {version} (build {build_number}) is ready to build.")
    return Release(version, tag, build_number, identity, notes, source_sha)


# Build steps


def archive_and_export(release: Release) -> Path:
    build_dir = release.directory / "build"
    archive = build_dir / "VulkanGlass.xcarchive"
    step(f"Archiving {release.version} ({release.build_number})")
    run(
        [
            "xcodebuild",
            "archive",
            "-project",
            "VulkanGlass.xcodeproj",
            "-scheme",
            "VulkanGlass",
            "-configuration",
            "Release",
            "-destination",
            "generic/platform=macOS",
            "-archivePath",
            str(archive),
            "-derivedDataPath",
            str(build_dir / "DerivedData"),
            "-clonedSourcePackagesDirPath",
            str(PACKAGES),
            "CODE_SIGN_IDENTITY=Developer ID Application",
            "CODE_SIGN_STYLE=Manual",
            f"DEVELOPMENT_TEAM={TEAM_ID}",
            "ENABLE_HARDENED_RUNTIME=YES",
            "OTHER_CODE_SIGN_FLAGS=--timestamp",
            f"CURRENT_PROJECT_VERSION={release.build_number}",
            f"SPARKLE_FEED_URL={FEED_URL}",
            f"SPARKLE_PUBLIC_ED_KEY={SPARKLE_PUBLIC_ED_KEY}",
        ]
    )

    step("Exporting with Developer ID signing")
    options = build_dir / "ExportOptions.plist"
    options.write_bytes(plistlib.dumps(export_options(TEAM_ID)))
    export_dir = build_dir / "export"
    run(
        [
            "xcodebuild",
            "-exportArchive",
            "-archivePath",
            str(archive),
            "-exportPath",
            str(export_dir),
            "-exportOptionsPlist",
            str(options),
        ]
    )
    app = export_dir / APP_NAME
    if not app.is_dir():
        raise ReleaseError(f"Exported app not found at {app}")
    return app


def verify_app(app: Path, release: Release) -> None:
    step("Verifying the exported app")
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    extension = app / "Contents" / "PlugIns" / QUICK_LOOK_NAME / "Contents" / "Info.plist"
    extension_info = plistlib.loads(extension.read_bytes())
    expected = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleShortVersionString": release.version,
        "CFBundleVersion": str(release.build_number),
        "SUFeedURL": FEED_URL,
        "SUPublicEDKey": SPARKLE_PUBLIC_ED_KEY,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ReleaseError(f"{key} is {info.get(key)!r}, expected {value!r}")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if extension_info.get(key) != info[key]:
            raise ReleaseError(f"The Quick Look extension's {key} does not match the app")
    if extension_info.get("CFBundleIdentifier") != QUICK_LOOK_BUNDLE_ID:
        raise ReleaseError("The Quick Look extension has an unexpected bundle identifier")

    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    extension_bundle = extension.parent.parent
    run(["codesign", "--verify", "--strict", "--verbose=2", str(extension_bundle)])
    entitlements_output = output(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(extension_bundle)]
    ).stdout
    try:
        entitlements = plistlib.loads(entitlements_output.encode())
    except (ValueError, TypeError) as error:
        raise ReleaseError("The Quick Look extension's signed entitlements are unreadable") from error
    for entitlement in (
        "com.apple.security.app-sandbox",
        "com.apple.security.files.user-selected.read-only",
    ):
        if entitlements.get(entitlement) is not True:
            raise ReleaseError(f"The Quick Look extension signature lacks {entitlement}")
    details = output(["codesign", "--display", "--verbose=4", str(app)]).stderr
    for required, meaning in (
        (f"TeamIdentifier={TEAM_ID}", "signed by the release team"),
        ("(runtime)", "hardened runtime"),
        ("Timestamp=", "a secure timestamp"),
    ):
        if required not in details:
            raise ReleaseError(f"The app signature lacks {meaning}")


def notarize(path: Path) -> None:
    step(f"Notarizing {path.name} (this usually takes a few minutes)")
    result = output(
        [
            "xcrun",
            "notarytool",
            "submit",
            str(path),
            "--keychain-profile",
            NOTARY_PROFILE,
            "--wait",
            "--output-format",
            "json",
        ],
        check=False,
    )
    try:
        info = json.loads(result.stdout)
    except json.JSONDecodeError:
        info = {}
    status = info.get("status")
    if result.returncode == 0 and status == "Accepted":
        return
    submission = info.get("id")
    if submission:
        log = output(
            ["xcrun", "notarytool", "log", submission, "--keychain-profile", NOTARY_PROFILE],
            check=False,
        )
        print(log.stdout)
    detail = status or (result.stderr or result.stdout).strip()
    raise ReleaseError(f"Notarization of {path.name} failed: {detail}")


def notarize_app(app: Path, release: Release) -> None:
    submission = release.directory / "build" / "notarize-app.zip"
    run(["ditto", "-c", "-k", "--keepParent", str(app), str(submission)])
    notarize(submission)
    run(["xcrun", "stapler", "staple", str(app)])
    run(["xcrun", "stapler", "validate", str(app)])
    run(["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)])


def make_dmg(app: Path, release: Release) -> Path:
    step("Creating the website disk image")
    staging = release.directory / "build" / "dmg"
    staging.mkdir(parents=True)
    run(["ditto", str(app), str(staging / APP_NAME)])
    (staging / "Applications").symlink_to("/Applications")
    dmg = release.directory / DMG_NAME
    run(
        [
            "hdiutil",
            "create",
            "-volname",
            VOLUME_NAME,
            "-srcfolder",
            str(staging),
            "-fs",
            "HFS+",
            "-format",
            "UDZO",
            str(dmg),
        ]
    )
    run(["codesign", "--sign", release.identity, "--timestamp", str(dmg)])
    notarize(dmg)
    run(["xcrun", "stapler", "staple", str(dmg)])
    run(
        [
            "spctl",
            "--assess",
            "--type",
            "open",
            "--context",
            "context:primary-signature",
            "--verbose=2",
            str(dmg),
        ]
    )
    return dmg


def make_update_feed(app: Path, release: Release) -> tuple[Path, Path]:
    step("Creating the signed Sparkle update and appcast")
    updates = release.directory / "updates"
    updates.mkdir()
    archive = updates / release.zip_name
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
    # A same-named Markdown file becomes the update's embedded release notes.
    (updates / f"VulkanGlass-{release.version}.md").write_text(release.notes)
    download_prefix = f"https://github.com/{REPOSITORY}/releases/download/{release.tag}/"
    run(
        [
            str(SPARKLE_BIN / "generate_appcast"),
            "--download-url-prefix",
            download_prefix,
            "--embed-release-notes",
            "--link",
            f"https://github.com/{REPOSITORY}",
            str(updates),
        ]
    )
    appcast = updates / "appcast.xml"
    text = appcast.read_text()
    if published_build_numbers(text) != [release.build_number]:
        raise ReleaseError("The generated appcast does not contain exactly this build")
    enclosure = ET.fromstring(text).find("channel/item/enclosure")
    if enclosure is None or enclosure.get("url") != download_prefix + release.zip_name:
        raise ReleaseError("The generated appcast has an unexpected download URL")
    if not enclosure.get(f"{{{SPARKLE_NS}}}edSignature"):
        raise ReleaseError("The generated appcast update is not EdDSA-signed")
    return archive, appcast


def build(release: Release) -> list[Path]:
    if release.directory.exists():
        shutil.rmtree(release.directory)
    (release.directory / "build").mkdir(parents=True)
    app = archive_and_export(release)
    verify_app(app, release)
    notarize_app(app, release)
    dmg = make_dmg(app, release)
    archive, appcast = make_update_feed(app, release)
    notes = release.directory / "release-notes.md"
    notes.write_text(release.notes)
    print(f"\nRelease files are in {release.directory}")
    return [dmg, archive, appcast]


def publish(release: Release, assets: list[Path]) -> None:
    step(f"Publishing {release.tag}")
    if check_git_state(release.version, release.tag, publishing=True) != release.source_sha:
        raise ReleaseError("HEAD moved since the release was built; refusing to tag a different commit")
    run(["git", "tag", "--annotate", release.tag, "--message", f"Vulkan Glass {release.version}", release.source_sha])
    run(["git", "push", "origin", f"refs/tags/{release.tag}"])
    # Upload into a draft first so the latest/download links never see a
    # release with missing assets.
    run(
        [
            "gh",
            "release",
            "create",
            release.tag,
            "--repo",
            REPOSITORY,
            "--verify-tag",
            "--draft",
            "--title",
            f"Vulkan Glass {release.version}",
            "--notes-file",
            str(release.directory / "release-notes.md"),
            *map(str, assets),
        ]
    )
    view = ["gh", "release", "view", release.tag, "--repo", REPOSITORY]
    uploaded = set(output([*view, "--json", "assets", "--jq", ".assets[].name"]).stdout.split())
    missing = {asset.name for asset in assets} - uploaded
    if missing:
        raise ReleaseError(
            f"Draft release {release.tag} is missing {', '.join(sorted(missing))}; "
            "it was left unpublished."
        )
    run(["gh", "release", "edit", release.tag, "--repo", REPOSITORY, "--draft=false", "--latest"])

    try:
        published = latest_published_build()
        if published != release.build_number:
            print(
                f"warning: {FEED_URL} still reports build {published}. "
                "GitHub can take a minute to update the latest release."
            )
    except ReleaseError as error:
        print(f"warning: release is already public; could not verify the appcast: {error}")
    print(f"\nPublished https://github.com/{REPOSITORY}/releases/tag/{release.tag}")


# Subcommands


def setup() -> None:
    if not DEVELOPER_DIR.exists():
        raise ReleaseError("Xcode.app not found at /Applications/Xcode.app")
    run([sys.executable, str(ROOT / "scripts" / "generate_xcodeproj.py")])
    resolve_packages()
    step("Sparkle update signing key")
    print("macOS may ask to allow access to the login Keychain.")
    # Creates the key only if the Keychain does not already have one.
    run([str(SPARKLE_BIN / "generate_keys")])
    key = keychain_public_key()
    if key is None:
        raise ReleaseError("generate_keys did not produce a readable key")
    if not SPARKLE_PUBLIC_ED_KEY:
        print(f'\nSet SPARKLE_PUBLIC_ED_KEY = "{key}" in scripts/release.py and commit it.')
    elif key != SPARKLE_PUBLIC_ED_KEY:
        raise ReleaseError("The Keychain key differs from SPARKLE_PUBLIC_ED_KEY")
    print(
        "Back up the private key somewhere safe and offline, for example with\n"
        f"  {SPARKLE_BIN / 'generate_keys'} -x ~/vulkanglass-sparkle-key.txt\n"
        "then move that file to your password manager and delete it. Losing the key "
        "means installed apps can no longer be updated."
    )

    for description, check in (
        ("Developer ID certificate", signing_identity),
        ("Notarization credentials", check_notary_profile),
    ):
        step(description)
        try:
            check()
            print("OK")
        except ReleaseError as error:
            print(f"Missing: {error}")


def check() -> None:
    """Report every publishing prerequisite, rather than stopping at the first."""
    if not DEVELOPER_DIR.exists():
        raise ReleaseError("Xcode.app not found at /Applications/Xcode.app")
    run([sys.executable, str(ROOT / "scripts" / "generate_xcodeproj.py")])
    results: list[tuple[str, str | None]] = []

    def verify(description: str, action) -> bool:
        try:
            action()
        except ReleaseError as error:
            results.append((description, str(error)))
            return False
        results.append((description, None))
        return True

    versions: list[str] = []
    if verify("Version sources agree", lambda: versions.extend(read_versions())):
        verify(
            "Clean main, identical to origin/main, with an unused tag",
            lambda: check_git_state(*versions, publishing=True),
        )
    verify("GitHub push access", check_github)
    verify("Developer ID certificate", signing_identity)
    verify("Notarization credentials", check_notary_profile)
    if verify("Sparkle tools", resolve_packages):
        verify("Sparkle signing key", check_sparkle_key)
    verify(
        "Build number is newer than the published release",
        lambda: choose_build_number(
            int(git("rev-list", "--count", "HEAD")), latest_published_build()
        ),
    )

    step("Release prerequisites")
    for description, problem in results:
        print(f"  {'✗' if problem else '✓'} {description}")
        if problem:
            print(f"      {problem}")
    failed = sum(problem is not None for _, problem in results)
    if failed:
        raise ReleaseError(f"{failed} of {len(results)} prerequisites are not met")
    print("All release prerequisites are met.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("setup", help="one-time signing key and credential setup")
    commands.add_parser("check", help="verify publishing prerequisites without building")
    for name, help_text in (
        ("build", "build, notarize, and package without publishing"),
        ("publish", "build, then tag and publish the GitHub release"),
    ):
        command = commands.add_parser(name, help=help_text)
        command.add_argument(
            "--notes", metavar="FILE", help="Markdown release notes (default: from commits)"
        )
        command.add_argument(
            "--build-number",
            type=int,
            metavar="N",
            help="override the build number (default: commit count of HEAD)",
        )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.command == "setup":
            setup()
        elif args.command == "check":
            check()
        else:
            publishing = args.command == "publish"
            release = prepare(args, publishing)
            assets = build(release)
            if publishing:
                publish(release, assets)
    except ReleaseError as error:
        sys.exit(f"release: {error}")
    except subprocess.CalledProcessError as error:
        sys.exit(f"release: command failed with exit status {error.returncode}")
    except OSError as error:
        sys.exit(f"release: {error}")


if __name__ == "__main__":
    main()
