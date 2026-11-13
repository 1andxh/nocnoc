import AppKit
import ServiceManagement
import NocnocCore

enum Paths {
    static let support = NSHomeDirectory() + "/Library/Application Support/nocnoc"
    /// NOCNOC_SOCKET overrides for testing; the hook script honours the same variable.
    static let socket = ProcessInfo.processInfo.environment["NOCNOC_SOCKET"] ?? support + "/nocnoc.sock"
    static let log = NSHomeDirectory() + "/Library/Logs/nocnoc.log"
    static let payloads = NSHomeDirectory() + "/Library/Logs/nocnoc-payloads.log"
}

/// Owns the server and everything the menu shows. Main-thread only; the
/// server's background threads reach it through `awayFlag` (a lock-protected
/// copy) and `DispatchQueue.main.async`.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var away: Bool {
        didSet {
            UserDefaults.standard.set(away, forKey: "away")
            awayFlag.set(away)
            Log.info("away = \(away)")
            // Back at the desk: hand every waiting request back to the agent's own prompt.
            // (ask_user questions stay: their panel is the only place to answer them.)
            if !away {
                let n = pending.resolveAll(.released, where: { $0.event.hookEvent != "ask_user" })
                if n > 0 { Log.info("released \(n) pending request(s) because Away was turned off") }
            }
        }
    }
    /// Debug: save every raw hook payload to nocnoc-payloads.log. Off by default
    /// (payloads contain your commands); used to check a new agent's real format.
    @Published var recordPayloads: Bool {
        didSet {
            UserDefaults.standard.set(recordPayloads, forKey: "recordPayloads")
            recordFlag.set(recordPayloads)
            Log.info("recordPayloads = \(recordPayloads)")
        }
    }
    /// Keep prompt cards (and info notifications) out of the way while VS Code
    /// or a terminal is the app in front. See Presence.swift.
    @Published var quietInEditor: Bool {
        didSet {
            UserDefaults.standard.set(quietInEditor, forKey: "quietInEditor")
            Log.info("quietInEditor = \(quietInEditor)")
            PromptPanels.shared.refreshVisibility()
        }
    }
    @Published private(set) var editorFrontmost = false
    @Published private(set) var openAtLogin = false
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var waiting: [PendingRequest] = []
    @Published private(set) var serverStatus = "Starting…"
    @Published private(set) var notificationStatus = "Checking…"

    let notifier = Notifier()
    private let store = EventStore()
    private let pending = PendingRequests()
    private let awayFlag: LockedBool
    private let recordFlag: LockedBool
    private var server: UnixSocketServer?

    private init() {
        let saved = UserDefaults.standard.object(forKey: "away") as? Bool ?? true
        away = saved
        awayFlag = LockedBool(saved)
        let record = UserDefaults.standard.bool(forKey: "recordPayloads")
        recordPayloads = record
        recordFlag = LockedBool(record)
        quietInEditor = UserDefaults.standard.object(forKey: "quietInEditor") as? Bool ?? true
    }

    func start() {
        Log.rotateIfNeeded()
        setUpLoginItem()
        watchFrontmostApp()
        Log.info("nocnoc \(Router.version) starting, socket \(Paths.socket)")
        notifier.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.notificationStatus = status }
        }
        notifier.setUp()

        let flag = awayFlag
        let record = recordFlag
        let router = Router(
            store: store, pending: pending, isAway: { flag.get() },
            onEvent: { event in DispatchQueue.main.async { AppState.shared.received(event) } },
            onPending: { request in DispatchQueue.main.async { AppState.shared.held(request) } },
            onResolved: { request, outcome in DispatchQueue.main.async { AppState.shared.ended(request, outcome) } },
            onRawPayload: { agent, body in
                if record.get() { Log.payload(agent: agent, body) }
            }
        )
        let server = UnixSocketServer(path: Paths.socket, handler: router.handle)
        do {
            try server.start()
            self.server = server
            serverStatus = "Listening"
            Log.info("listening")
        } catch let error as UnixSocketServer.ServerError {
            if case .alreadyRunning = error {
                Log.info("another instance is running; quitting")
                NSApp.terminate(nil)
                return
            }
            serverStatus = "Failed: \(error)"
            Log.info("server failed: \(error)")
        } catch {
            serverStatus = "Failed: \(error)"
            Log.info("server failed: \(error)")
        }
    }

    // MARK: - Which app is in front

    private func watchFrontmostApp() {
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { AppState.shared.updateFrontmost(app) }
        }
    }

    private func updateFrontmost(_ app: NSRunningApplication?) {
        // nocnoc itself coming forward (you clicked a card) changes nothing.
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let inEditor = Presence.isEditor(app?.bundleIdentifier)
        guard inEditor != editorFrontmost else { return }
        editorFrontmost = inEditor
        PromptPanels.shared.refreshVisibility()
    }

    /// Whether a held request's card should be on screen right now.
    func showsCard(_ event: AgentEvent) -> Bool {
        Presence.showsCard(for: event, editorFrontmost: editorFrontmost, quietInEditor: quietInEditor)
    }

    // MARK: - Open at login

    /// The installed copy (~/Applications) turns "open at login" on once, the
    /// first time it runs. After that it's your choice in the menu.
    private func setUpLoginItem() {
        let installed = Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        if installed, !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            setOpenAtLogin(true)
        }
        refreshLoginItem()
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("open at login = \(on)")
        } catch {
            Log.info("open at login \(on) failed: \(error)")
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        openAtLogin = SMAppService.mainApp.status == .enabled
        Log.info("login item status: \(SMAppService.mainApp.status.rawValue) (app at \(Bundle.main.bundlePath))")
    }

    func stop() {
        pending.resolveAll(.released)
        server?.stop()
        server = nil
        Log.info("stopped")
    }

    // MARK: - Answering

    /// Called from a notification button or the menu. First answer wins;
    /// a click on something that already ended is ignored.
    func answer(_ id: UUID, _ outcome: Outcome) {
        if pending.resolve(id, outcome) {
            Log.info("request \(id.uuidString.prefix(8)) answered: \(outcome)")
        } else {
            Log.info("request \(id.uuidString.prefix(8)) already ended; ignoring \(outcome)")
        }
    }

    func answerQuestion(_ id: UUID, _ answers: [String: String]) {
        answer(id, .answered(answers))
    }

    /// "Answer in VS Code": release the request so the normal prompt can take it.
    func answerInEditor(_ id: UUID) {
        let dir = waiting.first { $0.id == id }?.event.projectDir
        answer(id, .released)
        Editor.focus(projectDir: dir)
    }

    // MARK: - Server callbacks (already hopped to main)

    private func received(_ event: AgentEvent) {
        if event.kind == .activity {
            // You answered in the editor and the session moved on.
            notifier.clearAttention(agent: event.agent, sessionID: event.sessionID)
            return
        }
        events = store.all
        // Claude's own "needs you" fires ~6s into a prompt. If nocnoc already
        // shows a card for that session, a banner on top would only compete.
        let cardShowing = event.kind == .attention && waiting.contains {
            $0.event.agent == event.agent && $0.event.sessionID == event.sessionID
        }
        let notify = event.shouldNotify && away && !cardShowing
            && Presence.notifies(editorFrontmost: editorFrontmost, quietInEditor: quietInEditor)
        Log.info("event \(event.agent)/\(event.hookEvent) project=\(event.project ?? "-") notify=\(notify)")
        if notify { notifier.post(event) }
    }

    private func held(_ request: PendingRequest) {
        events = store.all
        waiting = pending.all
        let seconds = Int(request.deadline.timeIntervalSinceNow.rounded())
        Log.info("holding \(request.id.uuidString.prefix(8)) \(request.event.toolName ?? "?") project=\(request.event.project ?? "-") for \(seconds)s")
        // Prompts go through the app only: a glass card plus a sound. No macOS
        // notification, which would land on top of the card and compete with it.
        // Shown now, or kept hidden until you leave the editor (Presence.swift).
        PromptPanels.shared.show(request)
    }

    private func ended(_ request: PendingRequest, _ outcome: Outcome) {
        waiting = pending.all
        Log.info("request \(request.id.uuidString.prefix(8)) ended: \(outcome)")
        // Claude may also have posted "needs you" for this same prompt: clear it too.
        notifier.clearAttention(agent: request.event.agent, sessionID: request.event.sessionID)
        PromptPanels.shared.close(request.id)
    }

    func sendTestNotification() {
        notifier.post(AgentEvent(agent: "nocnoc", hookEvent: "Test", sessionID: "test", projectDir: nil,
                                 title: "nocnoc test", body: "Notifications are working.", shouldNotify: true))
    }
}

final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

enum Log {
    private static let queue = DispatchQueue(label: "nocnoc.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    /// Keep logs from growing forever: past 1 MB, the current file becomes
    /// `<name>.1` (replacing the previous one) and a fresh file starts.
    static func rotateIfNeeded(limit: Int = 1_000_000) {
        for path in [Paths.log, Paths.payloads] {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            guard size > limit else { continue }
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }
    }

    static func payload(agent: String, _ body: Data) {
        let line = "=== \(formatter.string(from: Date())) \(agent)\n\(String(decoding: body, as: UTF8.self))\n"
        queue.async { append(line, to: Paths.payloads) }
    }

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { append(line, to: Paths.log) }
    }

    private static func append(_ line: String, to path: String) {
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
