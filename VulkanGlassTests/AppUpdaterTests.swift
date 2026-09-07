import AppKit
import SwiftUI
import XCTest
@testable import VulkanGlass

@MainActor
final class AppUpdaterTests: XCTestCase {
    private let validInfo: [String: Any] = [
        "SUFeedURL": "https://updates.example.com/appcast.xml",
        "SUPublicEDKey": Data(repeating: 42, count: 32).base64EncodedString()
    ]

    func testConfigurationRequiresHTTPSAndAnEd25519PublicKey() {
        XCTAssertTrue(UpdateConfiguration(info: validInfo).isValid)
        for feed in ["", "$(SPARKLE_FEED_URL)", "http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/appcast.xml"] {
            var info = validInfo
            info["SUFeedURL"] = feed
            XCTAssertFalse(UpdateConfiguration(info: info).isValid, feed)
        }
        for key in ["", "$(SPARKLE_PUBLIC_ED_KEY)", "invalid", Data(repeating: 0, count: 31).base64EncodedString()] {
            var info = validInfo
            info["SUPublicEDKey"] = key
            XCTAssertFalse(UpdateConfiguration(info: info).isValid, key)
        }
    }

    func testBuiltAppDoesNotPreselectAutomaticChecks() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks"))
    }

    func testBundledQuickLookVersionMatchesAppVersion() throws {
        let appVersion = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        let plugInsURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionBundle = try XCTUnwrap(
            Bundle(url: plugInsURL.appendingPathComponent("VulkanGlassQuickLook.appex"))
        )
        XCTAssertEqual(
            extensionBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appVersion
        )
    }

    func testTestHostCannotOptIntoUpdates() {
        for key in DevelopmentAuthentication.testEnvironmentKeys {
            XCTAssertTrue(UpdateConfiguration.updatesDisabled(
                environment: [key: "test"], arguments: ["--enable-updates"], isDebugBuild: false
            ))
        }
    }

    func testDebugBuildRequiresExplicitOptIn() {
        XCTAssertTrue(UpdateConfiguration.updatesDisabled(
            environment: [:], arguments: [], isDebugBuild: true
        ))
        XCTAssertFalse(UpdateConfiguration.updatesDisabled(
            environment: [:], arguments: ["--enable-updates", "--disable-auth"], isDebugBuild: true
        ))
    }

    func testReleaseBuildEnablesConfiguredUpdatesOutsideTests() {
        XCTAssertFalse(UpdateConfiguration.updatesDisabled(
            environment: [:], arguments: [], isDebugBuild: false
        ))
    }

    func testDisabledOrUnconfiguredUpdaterNeverConstructsDriver() {
        for (info, disabled) in [(validInfo, true), ([:], false)] {
            let updater = AppUpdater(configuration: UpdateConfiguration(info: info), disabled: disabled) {
                XCTFail("Must not instantiate Sparkle for disabled or unconfigured builds")
                return MockUpdateDriver()
            }
            updater.start()
            updater.checkForUpdates()
            updater.setAutomaticallyChecksForUpdates(true)
            XCTAssertFalse(updater.isStarted)
            XCTAssertFalse(updater.canCheckForUpdates)
            XCTAssertNotNil(updater.unavailableReason)
        }
    }

    func testStartsOnceAndReflectsDriverStateWithoutOverwritingPreference() {
        let driver = MockUpdateDriver()
        driver.automaticallyChecksForUpdates = false
        let updater = makeUpdater(driver)
        updater.start()
        updater.start()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(updater.canCheckForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertEqual(driver.preferenceWrites, 1) // Only the setup assignment above.

        driver.canCheckForUpdates = false
        driver.lastUpdateCheckDate = Date(timeIntervalSince1970: 123)
        driver.stateChanged?()
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertEqual(updater.lastUpdateCheckDate, driver.lastUpdateCheckDate)
    }

    func testManualChecksHonorTheDriverAvailabilityFlag() {
        let driver = MockUpdateDriver()
        let updater = makeUpdater(driver)
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 0)
        updater.start()
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        driver.canCheckForUpdates = false
        driver.stateChanged?()
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        driver.canCheckForUpdates = true
        driver.stateChanged?()
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 2)
    }

    func testSparkleDriverConstructsAndPublishesKVOState() {
        let driver = SparkleUpdateDriver()
        let originalPreference = driver.automaticallyChecksForUpdates
        var stateChanges = 0
        driver.stateChanged = { stateChanges += 1 }

        driver.automaticallyChecksForUpdates = !originalPreference
        XCTAssertEqual(driver.automaticallyChecksForUpdates, !originalPreference)
        XCTAssertGreaterThan(stateChanges, 0)

        driver.automaticallyChecksForUpdates = originalPreference
        XCTAssertEqual(driver.automaticallyChecksForUpdates, originalPreference)
    }

    func testSparkleDriverStartFailsClosedForTheUnconfiguredTestHost() throws {
        guard !UpdateConfiguration().isValid else {
            throw XCTSkip("A configured test host must not start a real update session")
        }
        let driver = SparkleUpdateDriver()
        XCTAssertThrowsError(try driver.start())
    }

    func testUpdateSettingsViewUsesAnExplicitUpdaterDependency() {
        let updater = AppUpdater(configuration: UpdateConfiguration(info: [:]), disabled: false)
        let hostingView = NSHostingView(rootView: UpdateSettingsView(updater: updater))
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 180)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    }

    func testPreferenceChangesReachDriverAndRemainIndependentOfManualChecks() {
        let driver = MockUpdateDriver()
        let updater = makeUpdater(driver)
        updater.start()
        updater.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(driver.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertEqual(driver.preferenceWrites, 1)
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
    }

    func testStartupFailureLeavesActionsDisabled() {
        let driver = MockUpdateDriver()
        driver.startError = NSError(domain: "UpdateTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid feed"])
        let updater = makeUpdater(driver)
        updater.start()
        updater.checkForUpdates()
        XCTAssertFalse(updater.isStarted)
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertTrue(updater.unavailableReason?.contains("Invalid feed") == true)
        XCTAssertEqual(driver.checks, 0)
        XCTAssertNil(driver.stateChanged)
    }

    private func makeUpdater(_ driver: MockUpdateDriver) -> AppUpdater {
        AppUpdater(configuration: UpdateConfiguration(info: validInfo), disabled: false) { driver }
    }
}

@MainActor
private final class MockUpdateDriver: UpdateDriving {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true { didSet { preferenceWrites += 1 } }
    var lastUpdateCheckDate: Date?
    var stateChanged: (() -> Void)?
    var starts = 0
    var checks = 0
    var preferenceWrites = 0
    var startError: Error?

    func start() throws {
        starts += 1
        if let startError { throw startError }
    }
    func checkForUpdates() {
        checks += 1
    }
}
