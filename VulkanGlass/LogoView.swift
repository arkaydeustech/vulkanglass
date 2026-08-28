import SwiftUI

/// Faceted glass mark, teal instead of Obsidian's purple gem.
struct LogoView: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let scale = s / 64
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }

            var gem = Path()
            gem.move(to: p(32, 4))
            gem.addLine(to: p(56, 20))
            gem.addLine(to: p(56, 44))
            gem.addLine(to: p(32, 60))
            gem.addLine(to: p(8, 44))
            gem.addLine(to: p(8, 20))
            gem.closeSubpath()
            context.fill(gem, with: .color(VGTheme.accentHover))

            var top = Path()
            top.move(to: p(32, 4))
            top.addLine(to: p(56, 20))
            top.addLine(to: p(32, 28))
            top.addLine(to: p(8, 20))
            top.closeSubpath()
            context.fill(top, with: .color(VGTheme.textAccent))

            var right = Path()
            right.move(to: p(32, 28))
            right.addLine(to: p(56, 20))
            right.addLine(to: p(56, 44))
            right.addLine(to: p(32, 60))
            right.closeSubpath()
            context.fill(right, with: .color(VGTheme.accentHover.opacity(0.9)))

            var left = Path()
            left.move(to: p(32, 28))
            left.addLine(to: p(8, 20))
            left.addLine(to: p(8, 44))
            left.addLine(to: p(32, 60))
            left.closeSubpath()
            context.fill(left, with: .color(VGTheme.accent))
        }
        .frame(width: size, height: size)
    }
}
