# Vulkan Glass agent notes

## Project setup

- This is a native macOS SwiftUI application. It requires the full Xcode app at
  `/Applications/Xcode.app`.
- Tool versions and development scripts are managed by mise (`mise.toml`). Run
  `mise install` once after cloning, then `mise run <task>` (list them with
  `mise tasks`). Node and the oxc tools are pinned there, with download URLs and
  checksums in the committed `mise.lock` (regenerate with `mise lock` after
  changing `[tools]`); the Python scripts run under the system `python3`.
- `VulkanGlass.xcodeproj/project.pbxproj` is generated. Make persistent project
  structure or build-setting changes in `scripts/generate_xcodeproj.py`, then run
  `mise run project` (or `python3 scripts/generate_xcodeproj.py`).
- Lint and format with oxc: `mise run lint` (oxlint) and `mise run format`
  (oxfmt); `mise run check` runs the formatting/lint checks plus the installer
  unit tests and the oxlint self-test (`mise run test:lint`). oxfmt formats the
  repository's own JSON/YAML tooling files, and oxlint lints any
  JavaScript/TypeScript that is added.
- The application is ad-hoc signed (`Sign to Run Locally`). Do not switch it to an
  Apple Development identity unless a development team and certificate have been
  explicitly configured for the workspace.
- Follow `docs/version-update.md` when changing the app version or build number.
- Releases are built and published locally by `scripts/release.py` (see
  `docs/app-updates.md`). Only run `mise run release` or `mise run release:build`
  when the user explicitly asks: they use the Developer ID key and Keychain,
  submit to Apple's notary service, and `release` publishes a public GitHub
  release. `mise run test:release` is safe to run at any time.

## Safe development launches

- Use `mise run build` (or `python3 scripts/build.py`) for normal agent builds and
  UI checks. It rebuilds and launches the app with `--disable-auth` by default.
- Local-only mode must not access the macOS Keychain, invoke `gh auth token`, save
  a PAT, or perform GitHub pull/push operations.
- Only use `mise run build --with-auth` (or `python3 scripts/build.py --with-auth`)
  when the user explicitly wants GitHub authentication tested and understands that
  macOS may display Keychain prompts.
- For launches outside the build script, pass `--disable-auth` or set
  `VULKANGLASS_DISABLE_AUTH=1`.
- The behavior is implemented by `DevelopmentAuthentication` and the guards in
  `VulkanGlass/AppModel.swift`. It is `#if DEBUG`-only: Release builds ignore both the
  launch argument and the environment variable.
- When the mode is active, `AppModel.authenticationDisabled` is true and the Settings and
  Welcome surfaces say so explicitly. If the UI instead reports "GitHub CLI was not found",
  that is a real missing `gh`, not the development switch.

## Tests

- Run the installer unit tests with `mise run test:install` (or
  `python3 -m unittest scripts.test_install`).
- Run the `VulkanGlassTests` XCTest suite with `mise run test`, which sets the
  full Xcode developer directory for you.
- The machine's global `xcode-select` may point to Command Line Tools. Run tests
  manually with the full Xcode developer directory explicitly:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -project VulkanGlass.xcodeproj \
      -scheme VulkanGlass \
      -destination 'platform=macOS' test
  ```

- Keep authentication dependencies mocked in unit tests; tests must not read real
  credentials or make live GitHub requests.
- `VulkanGlassTests` runs with `TEST_HOST` set to `VulkanGlass.app`, so every test run
  launches the real app and executes `AppModel.bootstrap()`. `DevelopmentAuthentication`
  therefore treats an XCTest host environment as local-only; without that, each run would
  read the Keychain and macOS would show an unlock prompt.
  `testRunningUnderXCTestDisablesAuthenticationInTheHostApp` guards this.
- If an aggregate test fails but its owning test file passes in isolation, follow
  the repository's flaky-test workflow and update `docs/flaky-tests.md` rather
  than skipping or loosening the test.
