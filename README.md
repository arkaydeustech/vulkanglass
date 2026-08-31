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

To build a Release app and install it in `/Applications`, replacing an existing
copy of Vulkan Glass there, run:

```bash
python3 scripts/install.py
```

The installer asks the copy running from `/Applications` to quit, waits for it to
close, and leaves the installed app closed. If Vulkan Glass declines to quit (for
example, because unsaved changes could not be written), installation stops without
force-quitting it. Save or discard those changes, quit the app, and rerun the command.

Run the installer from an administrator account when installing into `/Applications`.
Do not run the entire script with `sudo`; build and app-termination work must remain
in your login session. If needed, install into a writable per-user directory instead:

```bash
mkdir -p ~/Applications
python3 scripts/install.py --applications-dir ~/Applications
```

## Tests

Run the installer unit tests with:

```bash
python3 -m unittest scripts.test_install
```

The generated project includes the `VulkanGlassTests` XCTest target:

```bash
xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' test
```

The tests are hosted by `VulkanGlass.app`, so a test run launches the real app. Auth is
disabled automatically whenever the app detects an XCTest host environment, which keeps test
runs free of Keychain prompts.
