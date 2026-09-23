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

## One-time release configuration

The repository does not yet have a published update feed or a signing key.
Until configured, update controls are disabled with an explanation. Do not ship
a bootstrap release expecting to configure its trusted key afterward: the first
update-capable distributed app must already contain the feed URL and public key.
Older builds without Sparkle need one manual installation of that release.

1. Build once to resolve the pinned Sparkle package. Its tools are in
   `build/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
2. Run that directory’s `generate_keys` tool on the release maintainer’s Mac.
   This is an explicit release setup action: it creates a private signing key in
   the login Keychain and prints the public key. Back up the private key securely;
   never commit it. Normal development builds do not invoke this tool.
3. Choose a stable, publicly readable HTTPS appcast URL. One option for this
   repository is
   `https://github.com/arkaydeustech/vulkanglass/releases/latest/download/appcast.xml`.
   This URL only works after each latest non-prerelease release includes an
   `appcast.xml` asset and the repository/assets are publicly accessible.
   Private GitHub assets requiring a PAT are not supported by this setup.
4. Set `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` in
   `scripts/generate_xcodeproj.py`, then regenerate the project. These are public
   values and should be committed so every subsequent build has the same trust
   configuration. Alternatively, supply these two Xcode build settings when
   creating release archives. `VulkanGlass/Info.plist` expands those settings.

Keep the existing ad-hoc signing configuration for local development. For public
macOS distribution, configure Developer ID signing and notarization separately
once the team and certificate are available. Include Sparkle’s nested helpers and
the Quick Look extension in signing/export verification; follow
[Sparkle’s distribution guidance](https://sparkle-project.org/documentation/).
Do not remove signature verification to work around a packaging problem.

## Publishing each update

1. Follow [version-update.md](version-update.md). **Increase `CFBundleVersion`
   for every published update**, even if the public version also changes.
   Sparkle compares build numbers, not the public version label.
2. Build/export the configured Release app, sign and notarize it as appropriate,
   and finish stapling before packaging. Verify its embedded `SUFeedURL` and
   `SUPublicEDKey` and its code signature.
3. Put the app in a ZIP preserving permissions and symlinks, for example:

   ```bash
   mkdir -p output/updates
   ditto -c -k --sequesterRsrc --keepParent /path/to/VulkanGlass.app output/updates/VulkanGlass-0.3-2.zip
   ```

4. Use Sparkle’s `generate_appcast` to sign the archive and generate the feed.
   For a GitHub release tagged `v0.3`, for example:

   ```bash
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
     --download-url-prefix https://github.com/arkaydeustech/vulkanglass/releases/download/v0.3/ \
     output/updates
   ```

   Use a clean staging directory for a single release with this tag-specific URL
   prefix. Optionally put a matching `.html` or `.md` release-notes file beside
   the ZIP before generation. The generator needs access to the signing key;
   use its `--help` for file-based signing in CI. Do not put private keys in the
   output directory or upload them. The public key embedded in both the old and
   new app must match the signing key.
5. Upload `appcast.xml`, the ZIP, and any referenced release notes/deltas to the
   same release. Check every enclosure URL resolves to the exact signed bytes.
   Publish only when all assets are present. Keep older download URLs available.
   No publishing is performed by the app or normal build scripts.

## Verification

- `python3 scripts/build.py` builds and launches with authentication and updates
  disabled. Debug builds only enable Sparkle with an explicit `--enable-updates`
  argument; XCTest hosts always disable it, even with that argument.
- Run the XCTest suite as documented in the repository. `AppUpdaterTests` uses
  a mock driver to cover trust configuration, lifecycle, persisted preference
  handling, availability gating, startup failures, and the test/development guard.
  It also constructs the real Sparkle adapter, exercises its KVO preference
  bridge, and verifies startup fails closed against the unconfigured test host
  before any network request can begin.
- For an actual installation smoke test, use two **disposable copies** with the
  same bundle ID and public key and increasing build numbers. Configure a test
  HTTPS feed before building. Launch the older copy with `--disable-auth
  --enable-updates` when using Debug. Check for updates, accept the download,
  relaunch, and verify the newer version and saved notes. Also test cancellation,
  an unreachable feed, a corrupt archive, and refusing quit after a failed save.
  Do not point a development feed at a working installation.

A real signed-feed download/install/relaunch test needs the maintainer’s release
configuration and signed update assets; the offline unit suite does not replace it.
