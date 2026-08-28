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
    static let titleBarHeight: CGFloat = 38
    static let statusBarHeight: CGFloat = 24
    static let sidebarWidth: CGFloat = 260
    static let trafficLightsInset: CGFloat = 78
}
