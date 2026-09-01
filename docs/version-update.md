# Updating the version

Vulkan Glass has a public version and a build number. Keep each value in sync
across its source files, then regenerate the Xcode project.

## Public version

For a public version change such as `0.2` to `0.3`, update all three source
locations:

1. Change `MARKETING_VERSION` in `scripts/generate_xcodeproj.py`. This is the
   persistent source for the generated Xcode build setting.
2. Change `CFBundleShortVersionString` in `VulkanGlass/Info.plist`. The app uses
   this explicit plist instead of an automatically generated one.
3. Change the `VulkanGlass/<version>` user-agent in
   `VulkanGlass/GitHubService.swift` so GitHub requests identify the same app
   version.

Do not edit `VulkanGlass.xcodeproj/project.pbxproj` directly. Regenerate it after
changing the generator:

```bash
python3 scripts/generate_xcodeproj.py
```

Avoid a repository-wide replacement of the old number: source and test files
contain unrelated decimal values such as colors, timing constants, and IP
addresses.

## Build number

The build number is independent of the public version. Only change it when the
release process or user explicitly requires a new build number. It must remain a
positive integer.

Update both locations, then regenerate the Xcode project:

- `CURRENT_PROJECT_VERSION` in `scripts/generate_xcodeproj.py`
- `CFBundleVersion` in `VulkanGlass/Info.plist`

## Verification

Check that the source values and both generated build configurations agree:

```bash
rg -n 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' \
  scripts/generate_xcodeproj.py VulkanGlass.xcodeproj/project.pbxproj
plutil -p VulkanGlass/Info.plist | rg \
  'CFBundleShortVersionString|CFBundleVersion'
rg -n 'VulkanGlass/[0-9]' VulkanGlass/GitHubService.swift
git diff --check
```

Review the final diff. A public-version-only update should normally touch:

- `scripts/generate_xcodeproj.py`
- `VulkanGlass.xcodeproj/project.pbxproj`
- `VulkanGlass/Info.plist`
- `VulkanGlass/GitHubService.swift`

If the build number also changes, its matching entries will appear in the first
three files.
