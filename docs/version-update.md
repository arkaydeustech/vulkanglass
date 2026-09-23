# Updating the version

Vulkan Glass has a public version and a build number. The public version is
changed by hand before a release; the build number is set by the release script.

## Public version

For a public version change such as `0.2` to `0.3`, update both source
locations:

1. Change `APP_MARKETING_VERSION` in `scripts/generate_xcodeproj.py`. This single
   persistent value supplies `MARKETING_VERSION` to the app and its bundled
   Quick Look extension; both `Info.plist` files expand `$(MARKETING_VERSION)`,
   so their public versions always match.
2. Change the `VulkanGlass/<version>` user-agent in
   `VulkanGlass/GitHubService.swift` so GitHub requests identify the same app
   version. The release script refuses to publish if the two differ.

Do not edit `VulkanGlass.xcodeproj/project.pbxproj` directly. Regenerate it after
changing the generator:

```bash
python3 scripts/generate_xcodeproj.py
```

Avoid a repository-wide replacement of the old number: source and test files
contain unrelated decimal values such as colors, timing constants, and IP
addresses.

Each public version is released once, as the tag `v<version>`. To publish another
release, change the version first. See [app-updates.md](app-updates.md).

## Build number

Do not change the build number by hand. `CURRENT_PROJECT_VERSION` stays `1` in
`scripts/generate_xcodeproj.py`, and both `Info.plist` files expand
`$(CURRENT_PROJECT_VERSION)`. The release script supplies a larger build number
for every published release, because Sparkle compares build numbers, not the
public version. See [app-updates.md](app-updates.md#build-numbers).

## Verification

Check that the source values and both generated build configurations agree:

```bash
rg -n 'APP_MARKETING_VERSION|MARKETING_VERSION' \
  scripts/generate_xcodeproj.py VulkanGlass.xcodeproj/project.pbxproj
rg -n 'VulkanGlass/[0-9]' VulkanGlass/GitHubService.swift
mise run test:release
git diff --check
```

Review the final diff. A public-version update should normally touch:

- `scripts/generate_xcodeproj.py`
- `VulkanGlass.xcodeproj/project.pbxproj`
- `VulkanGlass/GitHubService.swift`

Confirm the generated project contains the new `MARKETING_VERSION` for all four
app and Quick Look Debug/Release target configurations.
