import AppKit
import Observation
import SwiftUI

/// State that every window shares: settings, the GitHub connection, launch-only work, and the
/// list of open windows. Each window owns an `AppModel` for its own vault and tabs.
@MainActor
@Observable
final class AppSession {
    /// The running app's session. Tests build their own so they never see the host app's windows.
    static let shared = AppSession()

    var settings: AppSettings
    var githubUser: GitHubUser?
    var githubRepos: [GitHubRepo] = []
    var githubCLIStatus = GitHubCLIStatus()
    var githubAuthSource: GitHubAuthSource?
    var activeToken: String?
    var githubConnectionGeneration = 0
    /// Set after launch-only work finishes, so later windows do not repeat it.
    var hasBootstrapped = false
    private var bootstrapInProgress = false
    var pendingLaunchVaultPath: String?

    @ObservationIgnored private var windows: [WindowEntry] = []
    @ObservationIgnored private var openingVaults: [String: WeakModel] = [:]

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? SettingsStore.load()
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--vault"), args.indices.contains(index + 1) {
            pendingLaunchVaultPath = args[index + 1]
        }
    }

    /// Open windows' models, most recently focused first.
    var models: [AppModel] {
        windows.compactMap(\.model)
    }

    /// The model of the window the user worked in last; Finder opens go there.
    var activeModel: AppModel? { models.first }

    /// Adds a window's model. A newly opened window becomes the active one.
    func register(_ model: AppModel, window: NSWindow? = nil) {
        prune()
        if let index = windows.firstIndex(where: { $0.model === model }) {
            let entry = windows.remove(at: index)
            if let window { entry.window = window }
            windows.insert(entry, at: 0)
        } else {
            windows.insert(WindowEntry(model: model, window: window), at: 0)
        }
        if hasBootstrapped, pendingLaunchVaultPath != nil {
            Task { await openPendingLaunchVault() }
        }
    }

    /// Records the window hosting a registered model, so another window can bring it forward.
    func attach(_ window: NSWindow, to model: AppModel) {
        if let entry = windows.first(where: { $0.model === model }) {
            entry.window = window
        } else {
            register(model, window: window)
        }
    }

    func unregister(_ model: AppModel) {
        windows.removeAll { $0.model == nil || $0.model === model }
        openingVaults = openingVaults.filter { $0.value.model != nil && $0.value.model !== model }
    }

    /// Moves a model to the front when its window becomes key.
    func activate(_ model: AppModel) {
        guard let index = windows.firstIndex(where: { $0.model === model }), index != 0 else { return }
        windows.insert(windows.remove(at: index), at: 0)
    }

    func window(for model: AppModel) -> NSWindow? {
        windows.first { $0.model === model }?.window
    }

    /// Another window that already has the vault at `path` open, if any.
    func model(showingVault path: String, excluding model: AppModel) -> AppModel? {
        let target = canonicalPath(path)
        if let opening = openingVaults[target]?.model, opening !== model { return opening }
        return models.first { other in
            guard other !== model, let vault = other.vault else { return false }
            return canonicalPath(vault.path) == target
        }
    }

    /// The existing window that owns a file, including a vault note not yet open as a tab.
    func model(owningFile path: String, excluding model: AppModel) -> AppModel? {
        let target = canonicalPath(path)
        let others = models.filter { $0 !== model }
        if let vaultOwner = others.first(where: {
            guard let vault = $0.vault else { return false }
            return target.hasPrefix(canonicalPath(vault.path) + "/")
        }) { return vaultOwner }
        return others.first { other in
            other.tabs.contains { canonicalPath($0.path) == target }
        }
    }

    /// Reserves a vault before an async inspect or workspace transition can suspend.
    func reserveVault(_ path: String, for model: AppModel) -> Bool {
        let target = canonicalPath(path)
        guard openingVaults[target]?.model == nil else { return false }
        openingVaults[target] = WeakModel(model)
        return true
    }

    func releaseVault(_ path: String, for model: AppModel) {
        let target = canonicalPath(path)
        if openingVaults[target]?.model === model { openingVaults.removeValue(forKey: target) }
    }

    func beginBootstrap() -> Bool {
        guard !hasBootstrapped, !bootstrapInProgress else { return false }
        bootstrapInProgress = true
        return true
    }

    func finishBootstrap() async {
        await openPendingLaunchVault()
        bootstrapInProgress = false
        hasBootstrapped = true
    }

    private func openPendingLaunchVault() async {
        guard let path = pendingLaunchVaultPath, let model = activeModel else { return }
        pendingLaunchVaultPath = nil
        await model.openVault(path: path)
        // The first window can close while GitHub or vault inspection is suspended.
        if !models.contains(where: { $0 === model }) {
            if model.vault != nil { await model.closeVault() }
            pendingLaunchVaultPath = path
            if activeModel != nil { await openPendingLaunchVault() }
        }
    }

    private func canonicalPath(_ path: String) -> String {
        FileService.canonicalURL(URL(fileURLWithPath: path)).path
    }

    /// Brings the window showing `model` to the front.
    func focus(_ model: AppModel) {
        activate(model)
        guard let window = window(for: model) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func prune() {
        windows.removeAll { $0.model == nil }
    }

    private final class WindowEntry {
        weak var model: AppModel?
        weak var window: NSWindow?

        init(model: AppModel, window: NSWindow?) {
            self.model = model
            self.window = window
        }
    }

    private final class WeakModel {
        weak var model: AppModel?
        init(_ model: AppModel) { self.model = model }
    }
}

/// The focused window's model, for menu commands.
struct FocusedAppModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[FocusedAppModelKey.self] }
        set { self[FocusedAppModelKey.self] = newValue }
    }
}

/// Keeps the session told which window hosts a model, which one is in front, and stops a window
/// from closing until its notes are saved.
struct WindowSessionBridge: NSViewRepresentable {
    let session: AppSession
    let model: AppModel

    func makeNSView(context: Context) -> WindowSessionView {
        let view = WindowSessionView()
        view.session = session
        view.model = model
        return view
    }

    func updateNSView(_ nsView: WindowSessionView, context: Context) {
        nsView.session = session
        nsView.model = model
        nsView.installCloseGuard()
    }

    static func dismantleNSView(_ nsView: WindowSessionView, coordinator: ()) {
        nsView.stopObserving()
        nsView.restoreDelegate()
    }
}

final class WindowSessionView: NSView {
    weak var session: AppSession?
    weak var model: AppModel?
    private var keyObserver: NSObjectProtocol?
    private var closeGuard: WindowCloseGuard?
    private weak var guardedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if guardedWindow !== window { restoreDelegate() }
        stopObserving()
        guard let window else { return }
        if let session, let model { session.attach(window, to: model) }
        installCloseGuard()
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, let model = self.model else { return }
                session.activate(model)
            }
        }
        if window.isKeyWindow, let session, let model { session.activate(model) }
    }

    /// Wraps the window's delegate so closing waits for autosaves and asks about unsaved
    /// standalone files. SwiftUI may replace the delegate, so this re-checks on every update.
    func installCloseGuard() {
        guard let window, let model else { return }
        if let closeGuard, window.delegate === closeGuard {
            closeGuard.model = model
            return
        }
        if let existing = window.delegate as? WindowCloseGuard {
            existing.model = model
            closeGuard = existing
            guardedWindow = window
            return
        }
        let closeGuard = WindowCloseGuard(original: window.delegate, model: model)
        self.closeGuard = closeGuard
        guardedWindow = window
        window.delegate = closeGuard
    }

    func stopObserving() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    func restoreDelegate() {
        if let guardedWindow, let closeGuard, guardedWindow.delegate === closeGuard {
            guardedWindow.delegate = closeGuard.original
        }
        closeGuard = nil
        guardedWindow = nil
    }
}

/// A window delegate that asks the window's model before it closes and forwards everything else
/// to the delegate SwiftUI installed.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private(set) var original: NSWindowDelegate?
    weak var model: AppModel?
    private var closing = false

    init(original: NSWindowDelegate?, model: AppModel) {
        self.original = original
        self.model = model
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let originalAllows = original?.windowShouldClose?(sender) ?? true
        guard originalAllows else { return false }
        guard let model, model.needsPreparationBeforeClosing else { return true }
        guard !closing else { return false }
        closing = true
        Task { @MainActor [weak self, weak sender] in
            let ready = await model.prepareToCloseWindow()
            self?.closing = false
            if ready { sender?.close() }
        }
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
