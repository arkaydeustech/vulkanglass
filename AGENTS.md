# Vulkan Glass agent notes

## Project setup

- This is a native macOS SwiftUI application. It requires the full Xcode app at
  `/Applications/Xcode.app`.
- `VulkanGlass.xcodeproj/project.pbxproj` is generated. Make persistent project
  structure or build-setting changes in `scripts/generate_xcodeproj.py`, then run
  `python3 scripts/generate_xcodeproj.py`.
- The application is ad-hoc signed (`Sign to Run Locally`). Do not switch it to an
  Apple Development identity unless a development team and certificate have been
  explicitly configured for the workspace.
- Follow `docs/version-update.md` when changing the app version or build number.

## Safe development launches

- Use `python3 scripts/build.py` for normal agent builds and UI checks. It rebuilds
  and launches the app with `--disable-auth` by default.
- Local-only mode must not access the macOS Keychain, invoke `gh auth token`, save
  a PAT, or perform GitHub pull/push operations.
- Only use `python3 scripts/build.py --with-auth` when the user explicitly wants
  GitHub authentication tested and understands that macOS may display Keychain
  prompts.
- For launches outside the build script, pass `--disable-auth` or set
  `VULKANGLASS_DISABLE_AUTH=1`.
- The behavior is implemented by `DevelopmentAuthentication` and the guards in
  `VulkanGlass/AppModel.swift`. It is `#if DEBUG`-only: Release builds ignore both the
  launch argument and the environment variable.
- When the mode is active, `AppModel.authenticationDisabled` is true and the Settings and
  Welcome surfaces say so explicitly. If the UI instead reports "GitHub CLI was not found",
  that is a real missing `gh`, not the development switch.

## Tests

- The machine's global `xcode-select` may point to Command Line Tools. Run tests
  with the full Xcode developer directory explicitly:

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
