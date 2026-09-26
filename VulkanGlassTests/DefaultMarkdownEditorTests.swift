import XCTest
import AppKit
import SwiftUI
import Vision
import UniformTypeIdentifiers
@testable import VulkanGlass

@MainActor
final class DefaultMarkdownEditorTests: XCTestCase {
    private final class FakeWorkspace: MarkdownAssociationWorkspace {
        var handlers: [String: URL] = [:]
        var failures: Set<String> = []
        var calls: [String] = []

        func urlForApplication(toOpen contentType: UTType) -> URL? {
            handlers[contentType.identifier]
        }

        func setDefaultApplication(at applicationURL: URL, toOpen contentType: UTType) async throws {
            calls.append(contentType.identifier)
            if failures.contains(contentType.identifier) { throw SetDefaultFailed() }
            handlers[contentType.identifier] = applicationURL
        }
    }

    private final class FakeEditor {
        var status = MarkdownEditorStatus(isVulkanGlass: false, currentAppName: "TextEdit")
        var answer = true
        var failure: Error?
        var statusReads = 0
        var prompts = 0
        var makeDefaultCalls = 0

        var editor: DefaultMarkdownEditor {
            DefaultMarkdownEditor(
                status: {
                    self.statusReads += 1
                    return self.status
                },
                makeDefault: {
                    self.makeDefaultCalls += 1
                    if let failure = self.failure { throw failure }
                    self.status = MarkdownEditorStatus(isVulkanGlass: true, currentAppName: "Vulkan Glass")
                },
                confirmMakeDefault: {
                    self.prompts += 1
                    return self.answer
                },
                offersOnFirstLaunch: true
            )
        }
    }

    private struct SetDefaultFailed: LocalizedError {
        var errorDescription: String? { "Launch Services refused" }
    }

    private func dependencies(_ fake: FakeEditor) -> AppModelDependencies {
        var dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus() },
            githubUser: { _ in throw GitHubError.noToken },
            githubRepos: { _ in [] },
            loadKeychainToken: { nil },
            saveKeychainToken: { _ in },
            authenticationDisabled: { true }
        )
        dependencies.gitExecutablePath = { "/usr/bin/git" }
        dependencies.defaultMarkdownEditor = fake.editor
        return dependencies
    }

    private func hostSettings(for model: AppModel) -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(
            rootView: DefaultMarkdownEditorSettingsView().environment(model).frame(width: 520, height: 100)
        )
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (window, host)
    }

    private func renderedText<Content: View>(in host: NSHostingView<Content>) -> String {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return "" }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    func testFirstLaunchOffersAndSetsDefaultWhenAccepted() async {
        let fake = FakeEditor()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies(fake))

        await model.bootstrap()

        XCTAssertEqual(fake.prompts, 1)
        XCTAssertEqual(fake.makeDefaultCalls, 1)
        XCTAssertTrue(model.settings.checkedDefaultMarkdownEditor)
        XCTAssertEqual(model.markdownEditorStatus?.isVulkanGlass, true)
        XCTAssertFalse(model.settingDefaultMarkdownEditor)
        XCTAssertNil(model.errorMessage)
    }

    func testDecliningRecordsTheCheckWithoutChangingTheDefault() async {
        let fake = FakeEditor()
        fake.answer = false
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies(fake))

        await model.offerDefaultMarkdownEditorIfNeeded()

        XCTAssertEqual(fake.prompts, 1)
        XCTAssertEqual(fake.makeDefaultCalls, 0)
        XCTAssertTrue(model.settings.checkedDefaultMarkdownEditor)
        XCTAssertEqual(model.markdownEditorStatus?.isVulkanGlass, false)
    }

    func testOfferIsMadeOnlyOnce() async {
        let fake = FakeEditor()
        fake.answer = false
        let session = AppSession(settings: .default())
        let firstLaunch = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies(fake))

        await firstLaunch.offerDefaultMarkdownEditorIfNeeded()
        await firstLaunch.offerDefaultMarkdownEditorIfNeeded()
        // A later launch reads the flag back from the saved settings.
        let nextLaunch = AppModel(settings: session.settings, bootstrapOnLaunch: false, dependencies: dependencies(fake))
        await nextLaunch.bootstrap()

        XCTAssertEqual(fake.prompts, 1)
    }

    func testAlreadyDefaultDoesNotAsk() async {
        let fake = FakeEditor()
        fake.status = MarkdownEditorStatus(isVulkanGlass: true, currentAppName: "Vulkan Glass")
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies(fake))

        await model.offerDefaultMarkdownEditorIfNeeded()

        XCTAssertEqual(fake.prompts, 0)
        XCTAssertEqual(fake.makeDefaultCalls, 0)
        XCTAssertTrue(model.settings.checkedDefaultMarkdownEditor)
    }

    func testPreviouslyCheckedSettingsDoNotAsk() async {
        let fake = FakeEditor()
        var settings = AppSettings.default()
        settings.checkedDefaultMarkdownEditor = true
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies(fake))

        await model.offerDefaultMarkdownEditorIfNeeded()

        XCTAssertEqual(fake.statusReads, 0)
        XCTAssertEqual(fake.prompts, 0)
    }

    func testEditorThatDoesNotOfferLeavesTheFlagUnset() async {
        let fake = FakeEditor()
        var dependencies = self.dependencies(fake)
        dependencies.defaultMarkdownEditor.offersOnFirstLaunch = false
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)

        await model.bootstrap()

        XCTAssertEqual(fake.prompts, 0)
        XCTAssertFalse(model.settings.checkedDefaultMarkdownEditor)
    }

    func testOnlyTheFirstWindowOffers() async {
        let fake = FakeEditor()
        fake.answer = false
        let session = AppSession(settings: .default())
        let first = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies(fake))
        let second = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies(fake))

        await first.bootstrap()
        await second.bootstrap()

        XCTAssertEqual(fake.prompts, 1)
    }

    func testSetDefaultFromSettingsUpdatesStatus() async {
        let fake = FakeEditor()
        var settings = AppSettings.default()
        settings.checkedDefaultMarkdownEditor = true
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies(fake))

        model.refreshMarkdownEditorStatus()
        XCTAssertEqual(model.markdownEditorStatus?.currentAppName, "TextEdit")
        await model.makeDefaultMarkdownEditor()

        XCTAssertEqual(fake.makeDefaultCalls, 1)
        XCTAssertEqual(fake.prompts, 0)
        XCTAssertEqual(model.markdownEditorStatus?.isVulkanGlass, true)
    }

    func testFailedSetDefaultReportsAnError() async {
        let fake = FakeEditor()
        fake.failure = SetDefaultFailed()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies(fake))

        await model.makeDefaultMarkdownEditor()

        XCTAssertEqual(model.errorMessage?.contains("Launch Services refused"), true)
        XCTAssertEqual(model.markdownEditorError, model.errorMessage)
        XCTAssertEqual(model.markdownEditorStatus?.isVulkanGlass, false)
        XCTAssertFalse(model.settingDefaultMarkdownEditor)
    }

    func testTestHostNeverOffersOnLaunch() {
        // The unit tests launch the real app, whose bootstrap must not block on a modal alert.
        XCTAssertFalse(DefaultMarkdownEditor.live.offersOnFirstLaunch)
        XCTAssertFalse(AppModelDependencies.live.defaultMarkdownEditor.offersOnFirstLaunch)
        XCTAssertFalse(AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus() },
            githubUser: { _ in throw GitHubError.noToken },
            githubRepos: { _ in [] },
            loadKeychainToken: { nil },
            saveKeychainToken: { _ in }
        ).defaultMarkdownEditor.offersOnFirstLaunch)
    }

    func testSettingsDecodeMissingFlagAsUnchecked() throws {
        let legacy = """
        {"recentVaults":[],"vaultsRoot":"/tmp/vaults","autoSync":true}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.checkedDefaultMarkdownEditor)

        var settings = AppSettings.default()
        settings.checkedDefaultMarkdownEditor = true
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(roundTripped.checkedDefaultMarkdownEditor)
    }

    func testSettingsStatusText() {
        typealias View = DefaultMarkdownEditorSettingsView
        XCTAssertEqual(View.statusText(for: nil), "Checking…")
        XCTAssertEqual(
            View.statusText(for: MarkdownEditorStatus(isVulkanGlass: true, currentAppName: "Vulkan Glass")),
            "Vulkan Glass opens Markdown files."
        )
        XCTAssertEqual(
            View.statusText(for: MarkdownEditorStatus(isVulkanGlass: false, currentAppName: "TextEdit")),
            "Markdown files open in TextEdit."
        )
        XCTAssertEqual(
            View.statusText(for: MarkdownEditorStatus(isVulkanGlass: false, currentAppName: nil)),
            "No app is set to open Markdown files."
        )
    }

    func testSetDefaultButtonIsDisabledWhenAlreadyDefaultOrBusy() {
        typealias View = DefaultMarkdownEditorSettingsView
        let other = MarkdownEditorStatus(isVulkanGlass: false, currentAppName: "TextEdit")
        let ours = MarkdownEditorStatus(isVulkanGlass: true, currentAppName: "Vulkan Glass")
        XCTAssertFalse(View.setDefaultDisabled(status: other, inProgress: false))
        XCTAssertFalse(View.setDefaultDisabled(status: nil, inProgress: false))
        XCTAssertTrue(View.setDefaultDisabled(status: other, inProgress: true))
        XCTAssertTrue(View.setDefaultDisabled(status: ours, inProgress: false))
    }

    func testMarkdownTypesCoverDotMdWithoutDuplicates() {
        let types = MarkdownFileAssociation.markdownTypes
        XCTAssertEqual(types.first?.identifier, "net.daringfireball.markdown")
        XCTAssertTrue(types.contains { $0.identifier == "net.daringfireball.markdown" })
        XCTAssertEqual(Set(types).count, types.count)
    }

    func testMarkdownTypeIsImportedWithBothExtensions() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        let markdown = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown" })
        let tags = try XCTUnwrap(markdown["UTTypeTagSpecification"] as? [String: [String]])
        XCTAssertEqual(tags["public.filename-extension"], ["md", "markdown"])
    }

    func testStatusReportsMissingHandlerAndReadableAppName() {
        let workspace = FakeWorkspace()
        let type = UTType.plainText
        XCTAssertEqual(
            MarkdownFileAssociation.status(workspace: workspace, contentType: type),
            MarkdownEditorStatus(isVulkanGlass: false, currentAppName: nil)
        )

        workspace.handlers[type.identifier] = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let other = MarkdownFileAssociation.status(workspace: workspace, contentType: type)
        XCTAssertFalse(other.isVulkanGlass)
        XCTAssertEqual(other.currentAppName, "TextEdit")

        workspace.handlers[type.identifier] = Bundle.main.bundleURL
        let ours = MarkdownFileAssociation.status(workspace: workspace, contentType: type)
        XCTAssertTrue(ours.isVulkanGlass)
        XCTAssertEqual(ours.currentAppName, "VulkanGlass")
    }

    func testHandlerFallsBackToBundleURLWhenIdentifierIsMissing() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Unidentified.app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let plist: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleName": "Unidentified"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: appURL))
        XCTAssertNil(bundle.bundleIdentifier)
        XCTAssertTrue(MarkdownFileAssociation.isSameApp(appURL, as: bundle))
        XCTAssertFalse(MarkdownFileAssociation.isSameApp(appURL.deletingLastPathComponent(), as: bundle))
    }

    func testMakeDefaultContinuesAfterOneTypeFailsAndVerifiesDotMdHandler() async throws {
        let workspace = FakeWorkspace()
        let declared = UTType.plainText
        let resolved = UTType.json
        workspace.failures = [declared.identifier]

        try await MarkdownFileAssociation.makeDefault(
            workspace: workspace, types: [declared, resolved], statusType: resolved
        )

        XCTAssertEqual(workspace.calls, [declared.identifier, resolved.identifier])
        XCTAssertEqual(workspace.handlers[resolved.identifier], Bundle.main.bundleURL)
    }

    func testMakeDefaultThrowsWhenDotMdHandlerDidNotChange() async {
        let workspace = FakeWorkspace()
        let declared = UTType.plainText
        let resolved = UTType.json
        workspace.failures = [resolved.identifier]

        do {
            try await MarkdownFileAssociation.makeDefault(
                workspace: workspace, types: [declared, resolved], statusType: resolved
            )
            XCTFail("Expected the unresolved .md handler to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Launch Services refused")
        }
        XCTAssertEqual(workspace.calls, [declared.identifier, resolved.identifier])
    }

    func testGitWarningDefersTheFirstRunOfferUntilAQuietLaunch() async {
        let fake = FakeEditor()
        fake.answer = false
        var dependencies = self.dependencies(fake)
        dependencies.gitExecutablePath = { nil }
        let session = AppSession(settings: .default())
        let first = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies)
        await first.bootstrap()

        XCTAssertTrue(first.gitMissingWarningOpen)
        XCTAssertEqual(fake.prompts, 0)
        XCTAssertFalse(first.settings.checkedDefaultMarkdownEditor)

        dependencies.gitExecutablePath = { "/usr/bin/git" }
        let next = AppModel(settings: session.settings, bootstrapOnLaunch: false, dependencies: dependencies)
        await next.bootstrap()
        XCTAssertEqual(fake.prompts, 1)
        XCTAssertTrue(next.settings.checkedDefaultMarkdownEditor)
    }

    func testSettingsShowsSetDefaultErrorAndRefreshesOnActivation() async {
        let fake = FakeEditor()
        fake.failure = SetDefaultFailed()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies(fake))
        let (window, host) = hostSettings(for: model)
        defer { window.orderOut(nil) }

        XCTAssertGreaterThan(fake.statusReads, 0)
        await model.makeDefaultMarkdownEditor()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(renderedText(in: host).contains("Launch Services refused"))

        fake.status = MarkdownEditorStatus(isVulkanGlass: true, currentAppName: "Vulkan Glass")
        let readsBeforeActivation = fake.statusReads
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(fake.statusReads, readsBeforeActivation)
        XCTAssertTrue(renderedText(in: host).contains("Vulkan Glass opens Markdown files."))
    }

    func testSetDefaultIsDisabledWhileChangeIsInProgress() async {
        var dependencies = self.dependencies(FakeEditor())
        var resume: CheckedContinuation<Void, Never>?
        var calls = 0
        let started = expectation(description: "default association started")
        dependencies.defaultMarkdownEditor.makeDefault = {
            calls += 1
            await withCheckedContinuation { continuation in
                resume = continuation
                started.fulfill()
            }
        }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        let change = Task { await model.makeDefaultMarkdownEditor() }
        await fulfillment(of: [started], timeout: 1)

        XCTAssertTrue(model.settingDefaultMarkdownEditor)
        XCTAssertTrue(DefaultMarkdownEditorSettingsView.setDefaultDisabled(
            status: model.markdownEditorStatus,
            inProgress: model.settingDefaultMarkdownEditor
        ))
        await model.makeDefaultMarkdownEditor()
        XCTAssertEqual(calls, 1)

        resume?.resume()
        await change.value
        XCTAssertFalse(model.settingDefaultMarkdownEditor)
    }

    func testHandlerMatchesByBundleIdentifier() {
        XCTAssertTrue(MarkdownFileAssociation.isSameApp(Bundle.main.bundleURL, as: .main))
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        XCTAssertFalse(MarkdownFileAssociation.isSameApp(textEdit, as: .main))
    }

    func testFirstRunAlertOffersSetDefault() {
        let alert = DefaultMarkdownEditorAlert.make()
        XCTAssertEqual(alert.buttons.map(\.title), ["Set Default", "Not Now"])
    }
}
