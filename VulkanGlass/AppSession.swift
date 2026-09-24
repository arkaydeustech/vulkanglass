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
    /// Set when the first window runs the launch-only work (git check, GitHub sign-in, `--vault`),
    /// so windows opened later do not repeat it.
    var hasBootstrapped = false

    @ObservationIgnored private var windows: [WindowEntry] = []

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? SettingsStore.load()
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
        let target = FileService.canonicalURL(URL(fileURLWithPath: path)).path
        return models.first { other in
            guard other !== model, let vault = other.vault else { return false }
            return FileService.canonicalURL(URL(fileURLWithPath: vault.path)).path == target
        }
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
    }
}

final class WindowSessionView: NSView {
    weak var session: AppSession?
    weak var model: AppModel?
    private var keyObserver: NSObjectProtocol?
    private var closeGuard: WindowCloseGuard?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        let closeGuard = WindowCloseGuard(original: window.delegate, model: model)
        self.closeGuard = closeGuard
        window.delegate = closeGuard
    }

    func stopObserving() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }
}

/// A window delegate that asks the window's model before it closes and forwards everything else
/// to the delegate SwiftUI installed.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private(set) weak var original: NSWindowDelegate?
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
