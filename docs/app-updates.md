# App updates

Vulkan Glass uses [Sparkle 2](https://sparkle-project.org/documentation/) for
scheduled update checks, release notes, signed downloads, installation, and
relaunch. The app menu and Settings both have **Check for Updates…**. Automatic
checks are offered on Sparkle’s standard second-launch permission prompt. If the
user opts in, checks run daily; they can change that preference in Settings and
still check manually. Sparkle remembers the choice across launches. An available
update presents Sparkle’s **Install Update** action and download progress,
followed by **Install and Relaunch**. Users can defer or skip an update. Updates
are not silently downloaded or installed.

The existing application termination delegate saves dirty notes before allowing
quit; a failed save cancels termination. Sparkle handles network errors,
unsupported macOS versions, invalid signatures, and installation permissions.

## How releases work

Releases are built and published from the release maintainer's Mac by
`scripts/release.py`, never by CI. Signing, notarization, and the Sparkle key
stay in that Mac's login Keychain; no release secrets are stored in GitHub.

`mise run release` (`python3 scripts/release.py publish`):

1. Regenerates the project and checks that the working tree is clean, `main`
   matches `origin/main`, the version in `scripts/generate_xcodeproj.py` matches
   the `GitHubService.swift` user agent, and the tag `v<version>` does not exist.
2. Checks the Developer ID certificate, notarization credentials, and that the
   Keychain's Sparkle key matches `SPARKLE_PUBLIC_ED_KEY` in `scripts/release.py`.
3. Archives a Release build signed with Developer ID and the hardened runtime,
   with the build number, `SPARKLE_FEED_URL`, and `SPARKLE_PUBLIC_ED_KEY` supplied
   as build settings, then exports it for Developer ID distribution.
4. Verifies the app's versions, feed, key, and signature, notarizes and staples
   it, and checks it with Gatekeeper.
5. Creates, signs, notarizes, and staples `VulkanGlass.dmg` for the website.
6. Zips the app for Sparkle and runs Sparkle's `generate_appcast`, which signs the
   zip with the Keychain key and writes `appcast.xml` with embedded release notes.
7. Rechecks the commit and clean tree, tags the exact commit that was built,
   pushes the tag, uploads the disk image, zip, and appcast to a draft GitHub
   release, and publishes it as the latest release once all assets are present.

Only builds made this way carry the update feed and key. Development builds,
tests, and `mise run install` builds leave `SPARKLE_FEED_URL` and
`SPARKLE_PUBLIC_ED_KEY` empty, so their update controls are disabled with an
explanation.

The stable public URLs always point at the newest release:

- Website download: `https://github.com/arkaydeustech/vulkanglass/releases/latest/download/VulkanGlass.dmg`
- Update feed: `https://github.com/arkaydeustech/vulkanglass/releases/latest/download/appcast.xml`

Each appcast lists only its own release; Sparkle needs only the newest entry.
Download URLs in an appcast are tag-specific, so never delete a published
release's assets.

## One-time setup on the release Mac

1. **Developer ID certificate.** The login Keychain needs a valid
   "Developer ID Application" certificate for team `QWD87G9T3P`
   (`security find-identity -v -p codesigning`).
2. **Notarization credentials.** Store them once as a Keychain profile. With an
   Apple ID and an app-specific password from <https://account.apple.com>:

   ```bash
   xcrun notarytool store-credentials vulkanglass-notary \
     --apple-id <your Apple ID> --team-id QWD87G9T3P
   ```

   An App Store Connect API key also works: pass `--key`, `--key-id`, and
   `--issuer` instead of `--apple-id`.
3. **Sparkle signing key.** Run `mise run release:setup`. It creates the key in
   the login Keychain if none exists (macOS may ask for Keychain access) and
   prints the public key. Commit that value as `SPARKLE_PUBLIC_ED_KEY` in
   `scripts/release.py`. Back up the private key offline with Sparkle's
   `generate_keys -x <file>` as the command suggests, and never commit it.
   Losing it means installed apps can no longer be updated; changing it breaks
   updates for every installed copy.

The Quick Look extension uses only App Sandbox and user-selected file access
entitlements. [Apple documents App Sandbox entitlements as unrestricted on
macOS](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles),
so Developer ID provisioning profiles are not required for either target. The
release script verifies the exported extension's signature and entitlements.

`mise run release:check` confirms everything is in place without building.

The first update-capable release must already contain the feed URL and public
key. Copies installed before it (0.2.1 and earlier) have no updater
configuration and need one manual installation from the disk image.

## Publishing a release

1. Bump the version following [version-update.md](version-update.md) and merge
   it to `main`. The build number is set automatically.
2. On the release Mac, check out `main`, pull, and run:

   ```bash
   mise run release
   ```

   Pass `--notes <file>` to use hand-written Markdown release notes. By default
   the notes list the `feat`, `fix`, and `perf` commit subjects since the previous
   tag; the first release uses a short summary instead.
3. Notarization usually takes a few minutes per submission, and there are two
   (the app, then the disk image). macOS may ask `codesign` and
   `generate_appcast` for Keychain access; choose **Always Allow**.

To rehearse without publishing, run `mise run release:build`. It produces the
same files in `output/release/v<version>/` and tags or uploads nothing. It also
runs from an uncommitted or non-`main` checkout, with a warning.

If publishing fails while the GitHub release is still a draft, fix the problem,
delete the draft release with `gh release delete`, then remove the pushed tag
with `git push origin :refs/tags/v<version>` and `git tag -d v<version>` before
retrying. If the release is already public, keep its tag and assets; inspect the
release and appcast before taking any recovery action. A temporary failure to
check the appcast after publication prints a warning and leaves the command
successful.

## Build numbers

Sparkle compares `CFBundleVersion`, not the public version. The release script
uses the number of commits in `main`'s history, which only grows, and refuses to
publish a build number that is not larger than the one in the published appcast.
`--build-number <n>` overrides it if the history ever changes. Development
builds keep build number 1, so they are always older than any release.

## Verification

- `mise run test:release` covers the release script's validation and mocked
  process flow. A full signed archive/export, notarization, and GitHub publish
  still require the release maintainer's credentials and are only run on request.
- `python3 scripts/build.py` builds and launches with authentication and updates
  disabled. Debug builds only enable Sparkle with an explicit `--enable-updates`
  argument, and have no feed unless one is supplied as a build setting; XCTest
  hosts always disable updates, even with that argument.
- Run the XCTest suite as documented in the repository. `AppUpdaterTests` uses
  a mock driver to cover trust configuration, lifecycle, persisted preference
  handling, availability gating, startup failures, and the test/development guard.
  It also constructs the real Sparkle adapter, exercises its KVO preference
  bridge, and verifies startup fails closed against the unconfigured test host
  before any network request can begin.
- After publishing, install the previous release from its disk image, choose
  **Check for Updates…**, install the update, and confirm the new version
  relaunches with saved notes intact.
