import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import VulkanGlass

@MainActor
final class DefaultMarkdownEditorTests: XCTestCase {
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
        XCTAssertEqual(types.first, UTType(filenameExtension: "md"))
        XCTAssertTrue(types.contains { $0.identifier == "net.daringfireball.markdown" })
        XCTAssertEqual(Set(types).count, types.count)
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
