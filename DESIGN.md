---
name: Vulkan Glass
description: Native macOS Markdown notes; vaults are GitHub repositories.
colors:
  lagoon-teal: "#14B8A6"
  lagoon-teal-bright: "#2ED4BF"
  lagoon-teal-deep: "#0D9487"
  drop-target-blue: "#3B82F5"
  editor-ground-dark: "#1E1E1E"
  chrome-ground-dark: "#161616"
  ribbon-ground-dark: "#111111"
  editor-ground-light: "#FFFFFF"
  chrome-ground-light: "#F2F2F2"
  ribbon-ground-light: "#EBEBEB"
  ink-dark: "#DCDDDE"
  ink-light: "#212121"
  ink-muted-dark: "#999999"
  ink-muted-light: "#666666"
  ink-faint-dark: "#666666"
  ink-faint-light: "#999999"
  divider-dark: "#2B2B2B"
  divider-light: "#E3E3E3"
  code-ground-dark: "#29292B"
  code-ground-light: "#F0F0F2"
  callout-note: "#599EF2"
  callout-important: "#B87AF2"
  callout-warning: "#F2AD38"
  callout-caution: "#E65252"
  graph-linked: "#45CF6E"
typography:
  display:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "34pt"
    fontWeight: 700
  headline:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "26pt"
    fontWeight: 700
  title:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "22pt"
    fontWeight: 700
  body:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "16pt"
    fontWeight: 400
    lineHeight: "+3pt leading"
  ui:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "13pt"
    fontWeight: 400
  label:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "10pt"
    fontWeight: 600
  mono:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "14pt"
    fontWeight: 400
rounded:
  xs: "3pt"
  sm: "4pt"
  md: "6pt"
  lg: "8pt"
  xl: "10pt"
  2xl: "12pt"
  pill: "999pt"
spacing:
  xs: "4pt"
  sm: "8pt"
  md: "10pt"
  lg: "12pt"
  xl: "14pt"
  2xl: "16pt"
  3xl: "24pt"
  document-inset: "56pt"
components:
  ribbon-button:
    backgroundColor: "transparent"
    textColor: "{colors.ink-muted-dark}"
    rounded: "{rounded.md}"
    size: "32pt"
  ribbon-button-active:
    backgroundColor: "rgba(20, 184, 166, 0.22)"
    textColor: "{colors.lagoon-teal-bright}"
    rounded: "{rounded.md}"
    size: "32pt"
  tab:
    backgroundColor: "transparent"
    textColor: "{colors.ink-muted-dark}"
    typography: "{typography.ui}"
    padding: "0 10pt"
    height: "44pt"
  tab-active:
    backgroundColor: "{colors.editor-ground-dark}"
    textColor: "{colors.ink-dark}"
    typography: "{typography.ui}"
    padding: "0 10pt"
    height: "44pt"
  file-row-selected:
    backgroundColor: "rgba(20, 184, 166, 0.30)"
    textColor: "{colors.ink-dark}"
    padding: "3pt 8pt"
  button-primary:
    backgroundColor: "{colors.lagoon-teal}"
    textColor: "#FFFFFF"
  command-palette:
    rounded: "{rounded.2xl}"
    width: "560pt"
  chip-latest:
    backgroundColor: "rgba(20, 184, 166, 0.20)"
    textColor: "{colors.lagoon-teal-deep}"
    rounded: "{rounded.pill}"
    padding: "1pt 5pt"
  status-bar:
    backgroundColor: "{colors.chrome-ground-dark}"
    textColor: "{colors.ink-muted-dark}"
    padding: "0 12pt"
    height: "24pt"
---

# Design System: Vulkan Glass

Values are SwiftUI/AppKit points, taken from `VulkanGlass/Theme.swift` (`VGTheme`) and the views
that render notes. `VGTheme` is the source of truth. The hex values above are exact conversions of
its sRGB component values. The app ships Light and Dark (or follows the system). Dark is the
everyday reference, and every ground and ink token has a light partner.

## Overview

**Creative North Star: "Ink on Glass"**

The workspace is a sheet of neutral glass: near-black (or near-white) grounds in three quiet tonal
steps, hairline dividers, and system type. Lagoon Teal is the ink. It marks what is linked,
selected, focused or active: wiki links and tags, the active ribbon icon, the focused tab's
underline, the keyboard row in the file tree, the text caret, and the active node in the graph.
Teal ink on glass is the whole identity. Everything else stays out of the way so the note can lead.

The layout is the familiar vault workspace: a ribbon, a file tree, tabbed and splittable editor
panes, and a right sidebar for graph, backlinks, outline and tags. It is drawn as a native Mac app,
not a copy of Obsidian. The chrome is dense and precise: 44pt title bar, 24pt status bar, 13pt UI
text. The writing surface is generous: 16pt body in a centred column of up to 780pt, 56pt side
insets, and 96pt of run-out below the last line.

Controls are quiet until touched. They sit flush with the chrome, without borders or boxes, and
show themselves only through a rounded tint on hover, selection or focus. They follow macOS
conventions: system controls, menus, sheets and keyboard shortcuts. The app must never read as a
web page in a window.

**Key Characteristics:**
- One ink: Lagoon Teal is the only brand colour. Other hues are functional (drop target, callouts,
  graph, syntax).
- Flat, tonal depth: three grounds and 1pt dividers. Material and shadow only on floating, transient
  surfaces.
- SF Pro throughout, with SF Mono for code. No brand typeface.
- Dense chrome, spacious prose.
- Light and Dark are equal citizens, built from paired tokens.

## Colors

A neutral grey glass in three tonal steps, carrying a single saturated teal ink.

### Primary
- **Lagoon Teal** (`lagoon-teal`): the ink. Used for active and focus fills (as a tint at 18–30%
  opacity), the focused tab's 2pt underline, the active file-tree row's 2pt leading bar, the editor
  caret and selection (28%), the active graph node, blockquote bars, prominent buttons (as the
  tint of `.borderedProminent`), and the Tip callout.
- **Lagoon Teal Bright** (`lagoon-teal-bright`): teal used as *text* or *glyph*. Wiki links,
  inline tags, active ribbon and title-bar icons, status messages, and the split-line glow.
- **Lagoon Teal Deep** (`lagoon-teal-deep`): the shaded face of the logo gem and the text of small
  teal chips (the history "Latest" badge).

### Secondary
- **Drop Target Blue** (`drop-target-blue`): used only to preview where a dragged tab or file will
  land (outlines at 1.5–2pt, fills at 12–18%). It is a functional signal, not a second brand
  colour.

### Neutral
- **Editor Ground** (`editor-ground-dark` / `editor-ground-light`): the note surface, the active
  tab, the graph canvas, and the Welcome screen's outer ground and Recent column.
- **Chrome Ground** (`chrome-ground-dark` / `chrome-ground-light`): title bar, sidebars, status bar,
  and the Welcome card's action column.
- **Ribbon Ground** (`ribbon-ground-dark` / `ribbon-ground-light`): the 44pt ribbon, the deepest
  step.
- **Ink** (`ink-dark` / `ink-light`): primary text.
- **Muted Ink** (`ink-muted-dark` / `ink-muted-light`): secondary text, inactive tabs, resting
  ribbon icons, subtitles.
- **Faint Ink** (`ink-faint-dark` / `ink-faint-light`): section labels, metadata, close glyphs,
  empty states.
- **Divider** (`divider-dark` / `divider-light`): 1pt hairlines between panes, tabs and bars.
- **Code Ground** (`code-ground-dark` / `code-ground-light`): fenced code blocks.
- **Hover**: white at 8% on dark, black at 6% on light. It also shades the selected (not keyboard
  focused) file-tree row.

### Functional hues
- **Callouts** (`callout-note`, `callout-important`, `callout-warning`, `callout-caution`; Tip uses
  Lagoon Teal): GitHub-style alert bars and titles. The same five colours appear in the editor and
  the reading view.
- **Graph Linked** (`graph-linked`): nodes linked to the active note. Unlinked nodes are neutral
  grey.
- **Syntax highlighting** (`CodeHighlight.swift`) has its own light and dark sets for keywords,
  strings, numbers, types, comments and so on. It stays inside code blocks.

### Named Rules
**The One Ink Rule.** Lagoon Teal is the only colour that means "this is yours, active, or
linked". Functional hues signal a specific job (drop here, warning, linked node) and never decorate.

**The Tint, Don't Fill Rule.** Teal shows up as a translucent tint behind a control (18–30%) or
a 2pt bar. It is never a solid teal slab behind chrome. The exception is the prominent button,
which uses the system's own tinted style.

**Known gap.** `lagoon-teal-bright` is used for link and tag text in both appearances. On the
light editor ground its contrast is about 1.8:1. A light-mode text teal (around
`lagoon-teal-deep` or darker) has not been introduced yet.

## Typography

**Display Font:** SF Pro (the system font)
**Body Font:** SF Pro (the system font)
**Label/Mono Font:** SF Mono (`monospacedSystemFont`) for inline code, code blocks and Raw mode

**Character:** Pure system type. The hierarchy comes from size and weight alone, so the app reads as
part of macOS and the note's words carry the personality.

### Hierarchy
- **Display** (bold, 34pt): the note title above the body, and H1 in the editor.
- **Headline** (bold, 26pt): H2 in the editor.
- **Title** (bold, 22pt): H3 in the editor. Deeper headings are 18pt bold.
- **Body** (regular, 16pt, +3pt line spacing): note text in both editor and reading view, in a
  column up to 780pt wide. Bold is 16pt bold. Sub/superscript and footnote markers are 11pt.
- **UI** (regular, 13pt): tab titles, commit subjects (12pt), sidebar and palette rows. These use
  the macOS text styles (`.body`, `.callout`, `.caption`) where SwiftUI provides them.
- **Label** (semibold, 10pt, uppercase): section labels such as FILES, RECENT and GITHUB, set in
  Faint or secondary ink.
- **Mono** (regular, 14pt): inline code and fenced code. Code-block language labels are 10–11pt.

### Named Rules
**The System Voice Rule.** Use SF Pro and SF Mono through the system font APIs. No bundled or
brand typefaces. Hierarchy is size and weight, never a second family.

**Known drift.** The reading view (`MarkdownPreviewView.headingFont`) uses 28 / 22 / 22 / 20pt
for H1 / H2 / H3 / H4+. The editor (`LivePreview.contentFont`) uses 34 / 26 / 22 / 18pt. The editor
scale is the one recorded above.

## Layout

A fixed native workspace, left to right:

- **Ribbon** (44pt wide, Ribbon Ground): 32pt icon buttons stacked from the top. The logo (vault
  switcher) and Settings sit at the bottom.
- **Left sidebar** (default 260pt, 180–560pt, never more than 80% of the window): file tree or
  search. Tree rows indent 12–14pt per level, with 3pt vertical padding.
- **Editor panes**: tab groups that split left/right or top/bottom. Each pane is at least 160pt and
  the editor at least 320pt. Panes are separated by 1pt lines with a 10pt drag handle that glows
  teal (0.18s ease-in-out) while it is being dragged.
- **Right sidebar** (same width rules): graph, backlinks, outline, tags.
- **Title bar** (44pt: 28pt icons plus 8pt above and below) runs across the top, with a 96pt inset
  for the traffic lights and 16pt trailing inset. **Status bar** (24pt) runs along the bottom.

The note column is centred in its pane and capped at 780pt, with 56pt horizontal padding and 96pt
of bottom padding. A wide pane centres the column; a narrow one lets it fill the pane.

Spacing is small-step and tight in chrome (4, 6, 8, 10, 12, 14pt). It is wider in sheets and cards
(20–28pt padding). Sheets have fixed sizes: Settings 520 × 720, create/clone 520 × 420, small
confirmations 420 × 220. The command palette is 560pt wide, with rows of 8pt × 14pt padding and
a list up to 320pt tall.

## Elevation & Depth

Flat and tonal. Depth at rest comes only from the three grounds (ribbon, then chrome, then editor)
and 1pt dividers. The active tab "joins" the editor by taking Editor Ground. Material and shadow
are reserved for surfaces that float above the workspace for a moment.

### Shadow Vocabulary
- **Error toast** (black at 25%, 10pt blur radius, 4pt y-offset, over `.ultraThinMaterial`, up to
  480pt wide): drops in from the top edge below the title bar with a 0.2s ease-in-out move and fade.
  It is the only shadow on a container.
- **Split glow** (Lagoon Teal, 5pt radius, fades in over 0.18s): only on a pane divider while it is
  being dragged.
- **Palette material** (`.ultraThinMaterial` plus a 1pt divider stroke, no drop shadow): the
  command and quick-switch palettes, and the busy-message pill.

### Named Rules
**The Flat-at-Rest Rule.** Resting surfaces never cast shadows. Shadow and material belong to
floating, transient surfaces (palettes, toasts, drag previews) and to state (the split glow).

## Shapes

Gently rounded, small radii on a mostly rectilinear workspace. The panes, bars and sidebars
themselves are square and meet at hairlines.

- **3–4pt** (`xs`, `sm`): drop-target outlines in the file tree and tab strip.
- **6pt** (`md`): the workhorse. Ribbon and title-bar icon tints, tab drag previews, pane drop
  previews.
- **8pt** (`lg`): small popovers and pills. The wiki-link picker (360pt wide, Chrome Ground,
  1pt divider stroke) and the busy-message pill.
- **10pt** (`xl`): the error toast.
- **12pt** (`2xl`): large floating surfaces and cards (the command palette, the Welcome card).
- **Capsule** (`pill`): small badges and tag chips (the "Latest" commit badge, tags in the sidebar).

Active state on lists and tabs is drawn as a straight 2pt teal bar (leading edge in the tree,
bottom edge on tabs), not as a rounded pill.

## Components

### Ribbon and title-bar icon buttons
*Quiet until touched.*
- **Shape:** 32pt square (title bar: 28pt), 6pt radius tint.
- **Resting:** SF Symbol at 15pt in Muted Ink, no background.
- **Active:** Lagoon Teal Bright glyph on a Lagoon Teal tint (22% in the ribbon, 18% in the title
  bar).
- Tooltips (`.help`) name every icon-only control.

### Tabs
- **Shape:** square, 44pt tall, 100–200pt wide, 10pt horizontal padding, 1pt divider on the trailing
  edge.
- **Inactive:** transparent on Chrome Ground, 13pt Muted Ink title, 8pt bold close glyph in Faint Ink.
- **Active:** takes Editor Ground and Ink. Only the focused group's active tab carries the 2pt
  Lagoon Teal bottom bar, so the focused pane is always obvious.
- **Dirty:** a leading "• " on the title.
- **Dragging:** the drop zone previews in Drop Target Blue (2pt outline, 6pt radius, 12% fill),
  moving between zones with a 0.12s ease-out.

### File tree rows
- **Resting:** no background, indented by depth.
- **Selected:** Hover shade.
- **Keyboard focus / picked folder:** Lagoon Teal tint (30% dark, 22% light).
- **Active note:** 2pt Lagoon Teal bar on the leading edge.
- **Drop target:** Drop Target Blue at 18%, with a 1.5pt outline on folders (3pt radius).
- Each row is one accessibility element, with Rename and Move to Trash actions.

### Buttons
- **Primary:** the system `.borderedProminent` button tinted Lagoon Teal (Save token, Create, Clone).
- **Secondary:** system default and `.controlSize(.small)` buttons (for example "Reset to current
  commit"). Destructive actions use the system destructive role inside confirmation dialogs.
- **Inline actions** (Welcome card): unbordered rows with a 18pt teal SF Symbol, a 13pt title in
  Ink and a caption subtitle in Muted Ink.

### Command palette
- **Container:** 560pt wide, `.ultraThinMaterial`, 12pt radius, 1pt divider stroke, on a dismissing
  backdrop.
- **Field:** a native search field with 14pt padding, followed by a divider.
- **Rows:** 8pt × 14pt padding. The label is in Ink, with a right-aligned hint in secondary caption.

### Chips and tags
- **Inline tags in notes** (`#evergreen`): Lagoon Teal Bright text on a 22% teal background.
- **Badges** ("Latest"): 9pt semibold, capsule, 20% teal fill, Lagoon Teal Deep text, 5pt × 1pt
  padding.

### Status bar and history banner
- **Status bar:** 24pt, Chrome Ground, 1pt top divider, 12pt horizontal padding. Vault state on the
  left (a lock glyph turns teal in read-only mode); backlinks, word count and editor mode on the
  right.
- **History banner** (read-only history mode): 34pt tall, a teal wash (16% dark, 12% light) over
  Chrome Ground, a 1pt teal hairline (50%) on top, and small system buttons.

### Note surface (signature)
- Title (34pt bold) above the body. Body 16pt, +3pt leading, centred column of up to 780pt.
- Wiki links: Lagoon Teal Bright, underlined. Blockquotes: a teal bar with muted text. Callouts:
  a coloured bar and title in the callout hue. Code blocks: Code Ground, 14pt mono, a language
  label and syntax colours.
- Editor modes (Source, Reading, Raw) share the same centred column and 16pt body. Heading sizes
  currently differ between Source and Reading (see Typography, Known drift).

### Wiki-link picker
- A 360pt-wide popover on Chrome Ground with an 8pt radius and 1pt divider stroke. Below the list
  is a footer hint ("Enter to insert · Esc to dismiss") in 10pt Faint Ink, separated by a divider.

## Do's and Don'ts

### Do:
- **Do** take every colour, size and inset from `VGTheme`. Add new tokens there, with a dark and a
  light value, rather than writing `Color(red:…)` or `NSColor(red:…)` literals in a view.
- **Do** use Lagoon Teal as a tint (18–30%) or a 2pt bar to mark active, selected, focused or
  linked. Use Lagoon Teal Bright when teal is the text or glyph colour.
- **Do** use system controls (`.borderedProminent`, segmented pickers, toggles, sheets,
  confirmation dialogs, native search fields) and SF Symbols, sized to the 13pt UI and 15pt icon
  scale.
- **Do** keep depth tonal: ribbon, then chrome, then editor ground, with 1pt dividers.
- **Do** keep prose in the centred column of up to 780pt, at 16pt with +3pt leading.
- **Do** design every surface in both Light and Dark.

### Don't:
- **Don't** make the app look like a web app in a window: no custom web-style buttons, CSS-like
  cards, hover-only affordances without keyboard equivalents, or reinvented system controls.
- **Don't** clone Obsidian's look. Keep the familiar vault layout, but not its purple identity or
  its exact chrome. The ink is Lagoon Teal.
- **Don't** put shadows on resting surfaces (Flat-at-Rest Rule). Shadow and material are for
  palettes, toasts, drag previews and the split glow.
- **Don't** use Drop Target Blue or the callout hues for anything other than their job.
- **Don't** introduce a second type family. Hierarchy is SF Pro size and weight.
