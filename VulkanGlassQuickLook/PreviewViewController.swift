import AppKit
import Quartz
import SwiftUI
#if QUICK_LOOK_CONTROLLER_TESTING
@testable import VulkanGlass
#endif

final class PreviewViewController: NSViewController, QLPreviewingController {
    private var hostingController: NSViewController?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 640))
        preferredContentSize = NSSize(width: 760, height: 640)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let document = try await Task.detached(priority: .userInitiated) {
            try QuickLookPreviewDocument.load(from: url)
        }.value

        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()

        let hostingController = NSHostingController(
            rootView: QuickLookMarkdownView(document: document)
        )
        self.hostingController = hostingController
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
