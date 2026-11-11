import Foundation

public enum Decision: String, Codable, Equatable {
    case allow, deny
}

/// How a held request ended. Only `.decided` and `.answered` send anything back;
/// every other outcome is "no decision", so the agent's normal prompt takes over.
public enum Outcome: Equatable, CustomStringConvertible {
    case decided(Decision)
    case answered([String: String])   // question text -> chosen label(s) or typed text
    case timedOut     // nobody answered before the deadline
    case withdrawn    // the hook went away (agent killed it, or answered elsewhere)
    case released     // you chose "answer in VS Code", dismissed it, or turned Away off

    public var description: String {
        switch self {
        case .decided(let d): return d.rawValue
        case .answered(let a): return "answered \(a.count) question(s)"
        case .timedOut: return "timed out"
        case .withdrawn: return "withdrawn"
        case .released: return "released"
        }
    }
}

/// A permission request that a hook connection is waiting on.
public final class PendingRequest: Identifiable {
    public let id = UUID()
    public let event: AgentEvent
    public let deadline: Date
    fileprivate let signal = DispatchSemaphore(value: 0)
    fileprivate var outcome: Outcome?   // guarded by PendingRequests.lock

    init(event: AgentEvent, deadline: Date) {
        self.event = event
        self.deadline = deadline
    }
}

/// Registry of held requests. Thread-safe: server threads wait here, the UI
/// (main thread) resolves from here. The first resolution wins; later ones
/// (a double click, a click after timeout) are ignored.
public final class PendingRequests {
    private let lock = NSLock()
    private var items: [UUID: PendingRequest] = [:]

    public init() {}

    public func add(_ event: AgentEvent, deadline: Date) -> PendingRequest {
        let r = PendingRequest(event: event, deadline: deadline)
        lock.lock(); items[r.id] = r; lock.unlock()
        return r
    }

    /// Returns false if the request was already resolved (or never existed).
    @discardableResult
    public func resolve(_ id: UUID, _ outcome: Outcome) -> Bool {
        lock.lock()
        guard let r = items.removeValue(forKey: id), r.outcome == nil else {
            lock.unlock()
            return false
        }
        r.outcome = outcome
        lock.unlock()
        r.signal.signal()
        return true
    }

    @discardableResult
    public func resolveAll(_ outcome: Outcome, where include: (PendingRequest) -> Bool = { _ in true }) -> Int {
        lock.lock()
        let ids = items.values.filter(include).map(\.id)
        lock.unlock()
        return ids.filter { resolve($0, outcome) }.count
    }

    public var all: [PendingRequest] {
        lock.lock(); defer { lock.unlock() }
        return items.values.sorted { $0.deadline < $1.deadline }
    }

    /// Block the calling (server) thread until the request is resolved, its
    /// deadline passes, or the client hangs up. Checks every `pollInterval`.
    public func wait(_ r: PendingRequest, pollInterval: TimeInterval = 0.25,
                     isConnected: () -> Bool) -> Outcome {
        while true {
            if r.signal.wait(timeout: .now() + pollInterval) == .success {
                lock.lock(); defer { lock.unlock() }
                return r.outcome ?? .withdrawn
            }
            if Date() >= r.deadline, resolve(r.id, .timedOut) { return .timedOut }
            if !isConnected(), resolve(r.id, .withdrawn) { return .withdrawn }
            // If resolve() lost a race to another thread, the semaphore was
            // signalled and the next wait() returns that thread's outcome.
        }
    }
}
