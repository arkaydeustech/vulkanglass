# Vulkan Glass

Native macOS SwiftUI app for Markdown notes. Vaults are GitHub repositories; saving a note commits and pushes. Individual `.md` files can be opened outside a vault.

Accent color is teal. Layout follows Obsidian (ribbon, file tree, editor, backlinks, graph).

## Build

Requires Xcode. Scripts are Python (not Ruby):

```bash
python3 scripts/make_icons.py
python3 scripts/build.py
```

`build.py` compiles with `xcodebuild` and launches `Vulkan Glass.app`.
Development launches are local-only by default: they do not access the macOS
Keychain, invoke `gh auth token`, or perform GitHub network sync. To deliberately
test GitHub authentication, launch with:

```bash
python3 scripts/build.py --with-auth
```

For other Debug launch methods, pass `--disable-auth` as a launch argument or set
`VULKANGLASS_DISABLE_AUTH=1` in the scheme environment. Both switches are compiled
out of Release builds, so a shipped app always authenticates normally.

## Tests

The generated project includes the `VulkanGlassTests` XCTest target:

```bash
xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' test
```

The tests are hosted by `VulkanGlass.app`, so a test run launches the real app. Auth is
disabled automatically whenever the app detects an XCTest host environment, which keeps test
runs free of Keychain prompts.
