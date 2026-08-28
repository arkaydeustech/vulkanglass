import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: capture_window <owner-substring> <output.png>\n", stderr)
    exit(1)
}

let needle = args[1]
let output = URL(fileURLWithPath: args[2])
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

guard let window = info.first(where: { entry in
    let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
    let name = (entry[kCGWindowName as String] as? String) ?? ""
    let layer = entry[kCGWindowLayer as String] as? Int ?? 0
    return layer == 0 && (owner.localizedCaseInsensitiveContains(needle) || name.localizedCaseInsensitiveContains(needle))
}), let number = window[kCGWindowNumber as String] as? CGWindowID else {
    fputs("no window matching \(needle)\n", stderr)
    exit(2)
}

guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, number, [.boundsIgnoreFraming, .bestResolution]) else {
    fputs("capture failed\n", stderr)
    exit(3)
}

guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("could not write \(output.path)\n", stderr)
    exit(4)
}

CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print(output.path)
