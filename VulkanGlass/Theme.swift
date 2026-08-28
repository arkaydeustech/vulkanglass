import SwiftUI

/// Obsidian-like palette with teal in place of purple.
enum VGTheme {
    static let accent = Color(red: 0.08, green: 0.72, blue: 0.65)
    static let accentHover = Color(red: 0.05, green: 0.58, blue: 0.53)
    static let textAccent = Color(red: 0.18, green: 0.83, blue: 0.75)

    static func backgroundPrimary(dark: Bool) -> Color {
        dark ? Color(red: 0.118, green: 0.118, blue: 0.118) : Color.white
    }

    static func backgroundSecondary(dark: Bool) -> Color {
        dark ? Color(red: 0.086, green: 0.086, blue: 0.086) : Color(red: 0.95, green: 0.95, blue: 0.95)
    }

    static func backgroundTertiary(dark: Bool) -> Color {
        dark ? Color(red: 0.067, green: 0.067, blue: 0.067) : Color(red: 0.92, green: 0.92, blue: 0.92)
    }

    static func textNormal(dark: Bool) -> Color {
        dark ? Color(red: 0.863, green: 0.867, blue: 0.871) : Color(red: 0.13, green: 0.13, blue: 0.13)
    }

    static func textMuted(dark: Bool) -> Color {
        dark ? Color(red: 0.60, green: 0.60, blue: 0.60) : Color(red: 0.40, green: 0.40, blue: 0.40)
    }

    static func textFaint(dark: Bool) -> Color {
        dark ? Color(red: 0.40, green: 0.40, blue: 0.40) : Color(red: 0.60, green: 0.60, blue: 0.60)
    }

    static func divider(dark: Bool) -> Color {
        dark ? Color(red: 0.17, green: 0.17, blue: 0.17) : Color(red: 0.89, green: 0.89, blue: 0.89)
    }

    static func hover(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    static let ribbonWidth: CGFloat = 44
    static let titleBarHeight: CGFloat = 36
    static let titleBarIconSize: CGFloat = 28
    static let titleBarIconFont: CGFloat = 15
    static let statusBarHeight: CGFloat = 24
    static let sidebarWidth: CGFloat = 260
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 560
    static let sidebarMaxWindowFraction: CGFloat = 0.8
    static let trafficLightsInset: CGFloat = 78
    static let splitHandleWidth: CGFloat = 6
    static let editorMinWidth: CGFloat = 320
    static let collapsedLeftTitleBarInset = max(0, trafficLightsInset - ribbonWidth)

    /// Preferred sidebar width, never more than 80% of the window.
    static func cappedSidebarWidth(windowWidth: CGFloat) -> CGFloat {
        min(sidebarWidth, max(0, windowWidth * sidebarMaxWindowFraction))
    }

    /// Clamps the left sidebar while reserving fixed chrome and a usable editor.
    static func clampedLeftSidebarWidth(
        _ preferred: CGFloat,
        windowWidth: CGFloat,
        rightSidebarVisible: Bool
    ) -> CGFloat {
        let rightWidth = rightSidebarVisible ? cappedSidebarWidth(windowWidth: windowWidth) + 1 : 0
        let available = max(
            0,
            windowWidth - ribbonWidth - splitHandleWidth - rightWidth - editorMinWidth
        )
        let upper = min(sidebarMaxWidth, available)
        let lower = min(sidebarMinWidth, upper)
        return min(max(preferred, lower), upper)
    }
}
