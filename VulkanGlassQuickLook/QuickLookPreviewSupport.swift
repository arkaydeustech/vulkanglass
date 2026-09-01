import Foundation
import SwiftUI
#if QUICK_LOOK_CONTROLLER_TESTING
@testable import VulkanGlass
#endif

enum QuickLookPreviewError: LocalizedError, Equatable {
    case invalidTextEncoding
    case fileTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidTextEncoding:
            return "The Markdown file is not valid UTF-8 text."
        case .fileTooLarge(let maximumBytes):
            let limit = ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)
            return "The Markdown file is too large to preview. The maximum supported size is \(limit)."
        }
    }
}

struct QuickLookPreviewDocument: Equatable, Sendable {
    static let maximumByteCount = 5 * 1_024 * 1_024

    let text: String
    let baseURL: URL
    let blocks: [MDBlock]

    static func load(
        from url: URL,
        maximumByteCount: Int = QuickLookPreviewDocument.maximumByteCount
    ) throws -> QuickLookPreviewDocument {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumByteCount + 1) ?? Data()
        guard data.count <= maximumByteCount else {
            throw QuickLookPreviewError.fileTooLarge(maximumBytes: maximumByteCount)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw QuickLookPreviewError.invalidTextEncoding
        }
        return QuickLookPreviewDocument(
            text: text,
            baseURL: url.deletingLastPathComponent(),
            blocks: MDBlock.parse(text)
        )
    }
}

struct QuickLookMarkdownView: View {
    let document: QuickLookPreviewDocument
    @Environment(\.colorScheme) private var colorScheme

    static func isDark(colorScheme: ColorScheme) -> Bool {
        colorScheme == .dark
    }

    func markdownPreview(dark: Bool) -> MarkdownPreviewView {
        MarkdownPreviewView(
            text: document.text,
            noteTitles: [],
            baseURL: document.baseURL,
            dark: dark,
            loadLocalImages: false,
            loadRemoteImages: false,
            hidesLeadingTitle: false,
            parsedBlocks: document.blocks,
            onWiki: { _ in }
        )
    }

    var body: some View {
        let dark = Self.isDark(colorScheme: colorScheme)
        markdownPreview(dark: dark)
            .foregroundStyle(VGTheme.textNormal(dark: dark))
            .background(VGTheme.backgroundPrimary(dark: dark))
    }
}
