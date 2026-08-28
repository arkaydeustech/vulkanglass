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

## Tests

The generated project includes the `VulkanGlassTests` XCTest target:

```bash
xcodebuild -project VulkanGlass.xcodeproj -scheme VulkanGlass -destination 'platform=macOS' test
```
