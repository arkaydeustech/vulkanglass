# Vulkan Glass

Native macOS SwiftUI app for Markdown notes. Vaults are GitHub repositories; saving a note commits and pushes. Individual `.md` files can be opened outside a vault.

Accent color is teal. Layout follows Obsidian (ribbon, file tree, editor, backlinks, graph).

## Toolchain and tasks

Tool versions and the development scripts are managed by
[mise](https://mise.jdx.dev/). Install the pinned toolchain once, then run tasks
with `mise run <task>` (list them with `mise tasks`):

```bash
mise install
```

| Task | Description |
| --- | --- |
| `mise run start` | Regenerate the Xcode project, build, and launch the app |
| `mise run build` | Alias for `start` |
| `mise run install` | Build a Release app and install it in `/Applications` |
| `mise run project` | Regenerate `VulkanGlass.xcodeproj` |
| `mise run icons` | Regenerate the app icon assets |
| `mise run release` | Build, notarize, and publish the current `main` as a GitHub release |
| `mise run release:build` | Build, notarize, and package a release without publishing |
| `mise run release:check` | Verify the release prerequisites without building |
| `mise run release:setup` | One-time Sparkle signing key setup |
| `mise run test` | Run the `VulkanGlassTests` XCTest suite |
| `mise run test:install` | Run the installer unit tests |
| `mise run test:release` | Run the release script unit tests |
| `mise run test:lint` | Verify the oxlint rules actually apply |
| `mise run lint` | Lint with [oxlint](https://oxc.rs) |
| `mise run format` | Format with [oxfmt](https://oxc.rs) |
| `mise run check` | Check formatting and lint, then run the script unit tests and lint self-tests |

Node and the oxc tools are pinned in `mise.toml`, with their download URLs and
checksums recorded in `mise.lock`; the Python scripts below still run under the
system `python3`. oxfmt formats the repository's own JSON/YAML tooling files and
oxlint lints any JavaScript/TypeScript that is added.

## Build

Requires Xcode. Scripts are Python (not Ruby):

```bash
python3 scripts/make_icons.py
python3 scripts/build.py
```

The same steps are available as `mise run icons` and `mise run build`
(`mise run build` is an alias for `mise run start`). `build.py` compiles with
`xcodebuild` and launches `Vulkan Glass.app`.
Development launches are local-only by default: they do not access the macOS
Keychain, invoke `gh auth token`, or perform GitHub network sync. To deliberately
test GitHub authentication, launch with:

```bash
python3 scripts/build.py --with-auth
```

When using mise, the equivalent is `mise run build --with-auth`.

For other Debug launch methods, pass `--disable-auth` as a launch argument or set
`VULKANGLASS_DISABLE_AUTH=1` in the scheme environment. Both switches are compiled
out of Release builds, so a shipped app always authenticates normally.

To build a Release app and install it in `/Applications`, replacing an existing
copy of Vulkan Glass there, run:

```bash
python3 scripts/install.py
```

When using mise, the equivalent is `mise run install`.

The installed app includes a Finder Quick Look extension for Markdown files.
Select a `.md` file in Finder and press Space to open the rendered Vulkan Glass
preview. The extension can be enabled or disabled in System Settings under
General > Login Items & Extensions > Quick Look.

Quick Look previews do not load remote images or local images referenced beside
the selected Markdown file. Finder grants the sandboxed extension access to the
selected file, not its containing directory, so local images are shown with a
clear blocked-image placeholder. Markdown files larger than 5 MiB are rejected
with a preview error to keep Finder previews responsive.

macOS 26 requires third-party Quick Look extensions to come from a trusted,
production-signed app. The repository's ad-hoc `Sign to Run Locally` build still
compiles, embeds, signs, and registers the extension for development, but Finder
won't launch that local extension on macOS 26. A distributed build must use the
same Developer ID team for the app and extension, then be notarized and stapled.
The project intentionally leaves Developer ID configuration unset until a team
and certificate are configured for the workspace.

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

When using mise, the equivalent is `mise run install --applications-dir ~/Applications`.

## Tests

Run the installer unit tests with:

```bash
python3 -m unittest scripts.test_install
```

When using mise, the equivalent is `mise run test:install`.

The generated project includes the `VulkanGlassTests` XCTest target:

```bash
xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' test
```

When using mise, `mise run test` runs the same suite and sets the Xcode developer directory for you.

The tests are hosted by `VulkanGlass.app`, so a test run launches the real app. Auth is
disabled automatically whenever the app detects an XCTest host environment, which keeps test
runs free of Keychain prompts.

## App updates

The app integrates Sparkle for automatic update suggestions and in-app download,
installation, and relaunch. Use **Vulkan Glass > Check for Updates…** or the
Updates section in Settings. Sparkle asks before enabling automatic checks, and
the preference can be changed later in Settings. Release feed and signing-key
setup, publishing, and verification are documented in
[docs/app-updates.md](docs/app-updates.md). Only builds made by the release
script carry the update feed and public key; development and `mise run install`
builds have updates disabled.

## Releases

Releases are built, notarized, and published from the maintainer's Mac with
`mise run release`, which tags the current `main` commit and publishes a GitHub
release. The newest disk image is always available at
<https://github.com/arkaydeustech/vulkanglass/releases/latest/download/VulkanGlass.dmg>.
See [docs/app-updates.md](docs/app-updates.md).
