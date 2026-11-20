# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

Vulkan Glass is a **native macOS app** (SwiftUI and AppKit, macOS 14.0 or later). It is not an
iOS app. `ios` is recorded only because the schema has no macOS value, and it is the nearest
choice that loads Apple-native guidance. Follow the macOS Human Interface Guidelines. Where the
iPhone guidance differs (touch targets, tab bars, safe areas, edge-swipe back, Dynamic Type
sizing), Mac conventions win: menu bar commands and keyboard shortcuts, multiple windows,
pointer and hover, sidebars, sheets, context menus, and system Light/Dark appearance.

## Users

Two overlapping groups:

- **Obsidian-style note-takers.** People who work in a vault of linked Markdown notes, with a
  file tree, backlinks, an outline and a graph, and who want that workflow in a native Mac app
  backed by Git.
- **Developers.** People already at home with Git and GitHub who want their notes versioned,
  synced and recoverable the same way their code is.

Their job: write and link plain Markdown notes on a Mac, with sync and history coming from a
GitHub repository they own rather than from a proprietary service.

## Product Purpose

Vulkan Glass is a Markdown notes app where a vault is a GitHub repository. Saving a note commits
and pushes. Commit history can be browsed, viewed in a read-only history mode, and reset to an
earlier commit. Individual `.md` files outside a vault can also be opened and edited; they are
saved only on request (⌘S), never autosaved.

Success means a note-taker gets an Obsidian-familiar vault workflow in a fast native Mac app,
with notes that stay ordinary files in a repository they control.

## Positioning

The difference is native Mac and Git together, with equal weight on both. It is a true native
macOS app (not Electron or a web wrapper), and it uses GitHub repositories as the vault and sync
layer, with no proprietary sync service or storage format. Integration with Finder (Quick Look
previews, and offering to become the default Markdown app) is part of being native.

## Operating Context

- Runs on the user's Mac. Each window works on its own and can show a different vault or file.
  Opening a vault that another window already shows brings that window to the front.
- GitHub access goes through the GitHub CLI (`gh auth login`) when it is installed, or a
  personal access token with repo scope stored in the macOS Keychain.
- Vault entry points (Welcome screen): create a GitHub vault, clone a GitHub vault, open a local
  repository that already has a GitHub remote, open a standalone Markdown file, plus a Recent
  list.
- Workspace: a ribbon, a file tree and search on the left, an editor in tabbed panes that can be
  split into tab groups, and a right sidebar with graph, backlinks, outline and tags. The editor
  has Source, Reading and Raw modes.
- Finder: a Quick Look extension renders `.md` previews. It does not load remote images or
  images that sit beside the file, and it rejects files over 5 MiB.
- Distribution: notarized releases are published on GitHub
  (`arkaydeustech/vulkanglass`, DMG at `releases/latest/download/VulkanGlass.dmg`), and Sparkle
  handles in-app updates.

## Capabilities and Constraints

- **Obsidian-familiar layout is fixed.** Keep the ribbon, file tree, editor, and the
  backlinks/outline/graph sidebar, so Obsidian users feel at home.
- **Plain Markdown only.** Notes stay ordinary `.md` files (GitHub-flavoured Markdown with
  `[[wiki links]]`), with no proprietary format, database or sidecar store for note content.
- **Privacy-safe defaults.** Remote images in notes are off by default, because loading them can
  reveal the user's IP address to image hosts. Credentials live only in the Keychain or with
  `gh`. There is no telemetry or analytics.
- **Free and open source.** MIT-licensed and distributed through GitHub releases.
- Git is a runtime dependency. The app must handle a missing Git install gracefully.
- Quick Look on macOS 26 requires a Developer ID–signed, notarized build. Local development
  builds are ad-hoc signed.
- Terminology used in the UI: *vault* (a GitHub repository of notes), *note*, *standalone file*
  (a `.md` outside a vault), *sync*, *history mode*, *tab group*.
- **Open:** whether Vulkan Glass will ever target platforms other than macOS has not been
  decided. Treat it as macOS-only.

## Brand Commitments

- Name: **Vulkan Glass**.
- App icon and logo: `resources/icon.svg`, `resources/icon.png`,
  `VulkanGlass/Assets.xcassets/AppIcon.appiconset/`, and the in-app `LogoView`.
- Existing voice in the UI copy is plain, short and factual. It states what will happen, and
  states the trade-off where there is one (for example the remote-images privacy note). This is
  observed from the copy, not a separately confirmed voice guide.

## Evidence on Hand

- `SampleVault/`: a small sample vault of linked notes (Welcome, daily note, essays) for
  demonstrations and testing.
- `README.md` and `docs/` describe the features, release and update process.
- App icon assets (listed above).
- **Absent, so do not fabricate:** user counts, testimonials, reviews, press, benchmarks,
  performance claims, screenshots for marketing, and pricing. None exist.

## Product Principles

1. **Your notes are just files in your repo.** Never introduce lock-in: plain Markdown, standard
   Git, and a GitHub remote the user owns.
2. **Native first.** Behave like a well-made Mac app: system controls, menus, shortcuts,
   windows, Finder integration. Never a web page in a window.
3. **Familiar to Obsidian users.** Preserve the vault layout and linking workflow they already
   know. New features slot into that structure rather than replacing it.
4. **Git without ceremony.** Saving, syncing and history should feel like part of note-taking.
   Destructive Git actions (such as resetting to a commit) are explicit and confirmed.
5. **Private by default.** Network traffic is limited to Git and the GitHub API for the user's
   own repositories, plus Sparkle update checks (which Sparkle asks about before enabling).
   Anything else, such as remote images, is opt-in.
