import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: window_id <owner-substring>\n", stderr)
    exit(1)
}

let needle = args[1]
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

guard let window = info.first(where: { entry in
    let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
    let layer = entry[kCGWindowLayer as String] as? Int ?? 0
    return layer == 0 && owner.localizedCaseInsensitiveContains(needle)
}), let number = window[kCGWindowNumber as String] as? Int else {
    fputs("no window matching \(needle)\n", stderr)
    exit(2)
}

print(number)
