import Foundation

/// Thread-safe ring buffer of recent events. The socket server's threads write
/// to it; the UI reads it on the main thread.
public final class EventStore {
    private let lock = NSLock()
    private var events: [AgentEvent] = []
    private let capacity: Int

    public init(capacity: Int = 50) { self.capacity = capacity }

    public func append(_ e: AgentEvent) {
        lock.lock(); defer { lock.unlock() }
        events.insert(e, at: 0)
        if events.count > capacity { events.removeLast(events.count - capacity) }
    }

    public var all: [AgentEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// Maps requests to responses. No sockets or UI in here, so it's testable.
///
///   GET  /v1/health          is the app up? (and is Away on?)
///   GET  /v1/events          recent events, newest first (debugging)
///   POST /v1/hooks/<agent>   raw hook stdin JSON from an agent's hook
///   POST /v1/ask             an ask_user question from the MCP server (held until answered)
///
/// For a permission request, when Away is on and the hook said how long it
/// can wait (X-Nocnoc-Wait), the response is held until you answer. The
/// response body is then exactly what the hook prints back to the agent.
/// Everything else gets an empty body: "no decision".
public struct Router {
    /// The one place the version lives. build-app.sh copies it into the
    /// app's Info.plist (CFBundleShortVersionString), and release.sh expects
    /// a git tag `v<version>` on the commit being released.
    public static let version = "0.5.0"

    public let store: EventStore
    public let pending: PendingRequests
    public let isAway: () -> Bool
    /// An event to show (notify-only).
    public let onEvent: (AgentEvent) -> Void
    /// A request is now waiting for your answer.
    public let onPending: (PendingRequest) -> Void
    /// A held request ended, however it ended.
    public let onResolved: (PendingRequest, Outcome) -> Void
    /// Every hook body as received, before parsing (for the debug recorder).
    public let onRawPayload: (String, Data) -> Void
    /// Seconds we give back to the hook out of its stated wait, so we always
    /// answer before curl or the agent gives up on us.
    public let holdMargin: TimeInterval
    public let maxHold: TimeInterval

    public init(store: EventStore, pending: PendingRequests = PendingRequests(),
                isAway: @escaping () -> Bool,
                onEvent: @escaping (AgentEvent) -> Void = { _ in },
                onPending: @escaping (PendingRequest) -> Void = { _ in },
                onResolved: @escaping (PendingRequest, Outcome) -> Void = { _, _ in },
                onRawPayload: @escaping (String, Data) -> Void = { _, _ in },
                holdMargin: TimeInterval = 3, maxHold: TimeInterval = 3600) {
        self.store = store
        self.pending = pending
        self.isAway = isAway
        self.onEvent = onEvent
        self.onPending = onPending
        self.onResolved = onResolved
        self.onRawPayload = onRawPayload
        self.holdMargin = holdMargin
        self.maxHold = maxHold
    }

    public func handle(_ req: HTTPRequest, _ connection: ConnectionContext = .detached) -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/v1/health"):
            return .json(Health(ok: true, app: "nocnoc", version: Self.version, away: isAway()))
        case ("GET", "/v1/events"):
            return .json(store.all)
        case ("POST", let path) where path.hasPrefix("/v1/hooks/"):
            let agent = String(path.dropFirst("/v1/hooks/".count))
            guard Self.isValidAgentName(agent) else { return .error(404, "unknown agent name") }
            onRawPayload(agent, req.body)
            guard let event = AgentEvent.fromHookPayload(
                req.body, agent: agent, projectDirHint: req.headers["x-nocnoc-project-dir"]
            ) else {
                return .error(400, "body is not a JSON object")
            }
            // Activity events are frequent (every tool call) and only used to
            // clear notifications, so they stay out of the recent list.
            if event.kind != .activity { store.append(event) }
            if event.kind == .activity { settleAnsweredElsewhere(by: event) }
            return handleHook(event, req, connection)
        case ("POST", "/v1/ask"):
            return handleAsk(req, connection)
        case (_, "/v1/health"), (_, "/v1/events"), (_, "/v1/ask"):
            return .error(405, "method not allowed")
        default:
            return .error(404, "not found")
        }
    }

    private func handleHook(_ event: AgentEvent, _ req: HTTPRequest, _ connection: ConnectionContext) -> HTTPResponse {
        let hookWait = req.headers["x-nocnoc-wait"].flatMap(TimeInterval.init) ?? 0
        let hold = min(hookWait - holdMargin, maxHold)

        guard event.isAnswerable, isAway(), hold >= 1 else {
            onEvent(event)
            return .noDecision
        }

        let request = pending.add(event, deadline: Date().addingTimeInterval(hold))
        onPending(request)
        let outcome = pending.wait(request, isConnected: connection.isConnected)
        onResolved(request, outcome)

        switch (event.kind, outcome) {
        case (.permission, .decided(let decision)):
            return .json(PermissionReply(decision))
        case (.question, .decided(.deny)):
            return .json(PermissionReply(.deny))
        case (.question, .answered(let answers)):
            // Only answer if every question has an answer; otherwise let Claude ask normally.
            guard QuestionReply.isComplete(answers, for: event.questions ?? []),
                  let body = QuestionReply.make(toolInput: event.toolInput, answers: answers) else {
                return .noDecision
            }
            return HTTPResponse(status: 200, body: body)
        default:
            return .noDecision
        }
    }

    /// The agent shows its own prompt at the same time as our hook, and the
    /// first answer wins. When you answer in the editor, the agent doesn't
    /// cancel our hook, so we'd sit on a stale request until it times out.
    /// Activity from the same session settles it:
    /// - the same tool with the same input ran (PostToolUse/Failure) or was
    ///   denied (PermissionDenied): that's the request you just answered;
    /// - you sent a new message (UserPromptSubmit): the session has moved on.
    /// Matching on exact input matters: parallel tool calls in one session
    /// must not cancel a prompt that's still open.
    private func settleAnsweredElsewhere(by activity: AgentEvent) {
        guard let session = activity.sessionID else { return }
        pending.resolveAll(.answeredElsewhere, where: { held in
            guard held.event.agent == activity.agent, held.event.sessionID == session else { return false }
            if activity.hookEvent == "UserPromptSubmit" { return true }
            return held.event.toolName == activity.toolName && held.event.toolInput == activity.toolInput
        })
    }

    /// ask_user is held whether or not Away is on: the panel is the only place
    /// to answer it (there's no prompt in the editor to fall back to).
    private func handleAsk(_ req: HTTPRequest, _ connection: ConnectionContext) -> HTTPResponse {
        guard let ask = try? JSONDecoder().decode(AskRequest.self, from: req.body),
              !ask.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(400, "expected {\"question\": \"...\"}")
        }
        let wait = req.headers["x-nocnoc-wait"].flatMap(TimeInterval.init) ?? 0
        let hold = min(wait - holdMargin, maxHold)
        guard hold >= 1 else { return .json(AskResponse(status: .noAnswer, answer: nil, reason: "no time to wait")) }

        let event = AgentEvent.fromAsk(ask, projectDirHint: req.headers["x-nocnoc-project-dir"])
        store.append(event)
        let request = pending.add(event, deadline: Date().addingTimeInterval(hold))
        onPending(request)
        let outcome = pending.wait(request, isConnected: connection.isConnected)
        onResolved(request, outcome)

        if case .answered(let answers) = outcome,
           let answer = answers[ask.question]?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            return .json(AskResponse(status: .answered, answer: answer, reason: nil))
        }
        return .json(AskResponse(status: .noAnswer, answer: nil, reason: outcome.description))
    }

    public static func isValidAgentName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 32 && s.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }

    struct Health: Codable {
        let ok: Bool
        let app: String
        let version: String
        let away: Bool
    }
}

/// The JSON a PermissionRequest hook prints to answer. Same shape for Claude
/// Code and Codex (both documented as hookSpecificOutput.decision.behavior).
public struct PermissionReply: Codable, Equatable {
    public struct Output: Codable, Equatable {
        public let hookEventName: String
        public let decision: DecisionBody
    }
    public struct DecisionBody: Codable, Equatable {
        public let behavior: String
        public let message: String?   // deny only: tells the agent why
    }

    public let hookSpecificOutput: Output

    public static let denyMessage = "The user denied this from the nocnoc notification on their Mac."

    public init(_ decision: Decision) {
        hookSpecificOutput = Output(
            hookEventName: "PermissionRequest",
            decision: DecisionBody(behavior: decision.rawValue,
                                   message: decision == .deny ? Self.denyMessage : nil))
    }
}

/// Answering AskUserQuestion through a PermissionRequest hook (Claude Code
/// docs): allow, with `updatedInput` = the original tool input plus
/// `answers: {question text: chosen label}`. Multi-select labels are joined
/// with commas. "allow" without updatedInput is not enough for this tool.
public enum QuestionReply {
    public static func make(toolInput: Data?, answers: [String: String]) -> Data? {
        guard let toolInput,
              var input = (try? JSONSerialization.jsonObject(with: toolInput)) as? [String: Any] else { return nil }
        input["answers"] = answers
        let reply: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": input],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
    }

    public static func isComplete(_ answers: [String: String], for questions: [AgentEvent.Question]) -> Bool {
        !questions.isEmpty && questions.allSatisfy { q in
            !(answers[q.question]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    /// Multi-select: the chosen labels in the order they were offered, comma-joined.
    public static func join(_ chosen: Set<String>, in question: AgentEvent.Question) -> String {
        question.options.map(\.label).filter(chosen.contains).joined(separator: ", ")
    }
}

/// Body of POST /v1/ask (sent by nocnoc-mcp).
public struct AskRequest: Codable, Equatable {
    public var agent: String?
    public var question: String
    public var options: [String]?
    public var multiSelect: Bool?
    public var allowFreeText: Bool?
    public var context: String?
    public var projectDir: String?

    public init(agent: String? = nil, question: String, options: [String]? = nil, multiSelect: Bool? = nil,
                allowFreeText: Bool? = nil, context: String? = nil, projectDir: String? = nil) {
        self.agent = agent
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.allowFreeText = allowFreeText
        self.context = context
        self.projectDir = projectDir
    }
}

public struct AskResponse: Codable, Equatable {
    public enum Status: String, Codable { case answered, noAnswer = "no_answer" }
    public var status: Status
    public var answer: String?
    public var reason: String?
}

/// What the router can ask about the connection a request came in on.
public struct ConnectionContext {
    public let isConnected: () -> Bool

    public init(isConnected: @escaping () -> Bool) { self.isConnected = isConnected }

    /// For callers with no live connection (tests): always "still connected".
    public static let detached = ConnectionContext(isConnected: { true })
}
