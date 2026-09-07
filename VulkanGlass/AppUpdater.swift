import Combine
import Foundation
import Sparkle
import SwiftUI

struct UpdateConfiguration {
    let feedURL: String
    let publicKey: String

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        feedURL = (info["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        publicKey = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        guard let url = URL(string: feedURL), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let key = Data(base64Encoded: publicKey), key.count == 32 else { return false }
        return true
    }

    static let builtWithDebugConfiguration: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    static func updatesDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        isDebugBuild: Bool = builtWithDebugConfiguration
    ) -> Bool {
        // Tests must never create an updater, even when explicitly opted in.
        if DevelopmentAuthentication.isRunningTests(environment: environment) { return true }
        return isDebugBuild && !arguments.contains("--enable-updates")
    }
}

/// A small boundary lets tests exercise our lifecycle without network requests or installers.
@MainActor
protocol UpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    var stateChanged: (() -> Void)? { get set }
    func start() throws
    func checkForUpdates()
}

@MainActor
final class SparkleUpdateDriver: UpdateDriving {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var subscriptions = Set<AnyCancellable>()
    var stateChanged: (() -> Void)?

    init() {
        let updater = controller.updater
        Publishers.Merge3(
            updater.publisher(for: \.canCheckForUpdates).map { _ in () },
            updater.publisher(for: \.automaticallyChecksForUpdates).map { _ in () },
            updater.publisher(for: \.lastUpdateCheckDate).map { _ in () }
        )
        .sink { [weak self] in self?.stateChanged?() }
        .store(in: &subscriptions)
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
    func start() throws { try controller.updater.start() }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var unavailableReason: String?
    @Published private(set) var isStarted = false
    private let makeDriver: @MainActor () -> any UpdateDriving
    private var driver: (any UpdateDriving)?

    init(
        configuration: UpdateConfiguration = UpdateConfiguration(),
        disabled: Bool = UpdateConfiguration.updatesDisabled(),
        makeDriver: @escaping @MainActor () -> any UpdateDriving = { SparkleUpdateDriver() }
    ) {
        self.makeDriver = makeDriver
        if disabled {
            unavailableReason = "Updates are disabled in development and test builds."
        } else if !configuration.isValid {
            unavailableReason = "Updates aren’t configured for this build."
        }
    }

    /// Start once, after the app delegate has been connected to the note-saving model.
    func start() {
        guard !isStarted, unavailableReason == nil else { return }
        let driver = makeDriver()
        self.driver = driver
        driver.stateChanged = { [weak self] in self?.refresh() }
        do {
            try driver.start()
            isStarted = true
            refresh()
        } catch {
            unavailableReason = "Updates couldn’t start: \(error.localizedDescription)"
            driver.stateChanged = nil
            self.driver = nil
        }
    }

    func checkForUpdates() {
        guard isStarted, canCheckForUpdates else { return }
        driver?.checkForUpdates()
        refresh()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isStarted else { return }
        driver?.automaticallyChecksForUpdates = enabled
        refresh()
    }

    private func refresh() {
        guard isStarted, let driver else { return }
        canCheckForUpdates = driver.canCheckForUpdates
        automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates
        lastUpdateCheckDate = driver.lastUpdateCheckDate
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UPDATES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            if let reason = updater.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                .disabled(!updater.isStarted)
                Text("When an update is available, you’ll be offered a download and installation. You choose when to restart.")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = updater.lastUpdateCheckDate {
                    Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
