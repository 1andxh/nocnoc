import Foundation

/// A minimal MCP server (stdio transport) with one tool, `ask_user`.
///
/// MCP over stdio is JSON-RPC 2.0: one JSON message per line on stdin, one per
/// line on stdout. The agent sends `initialize`, then `tools/list` to learn our
/// tool, then `tools/call` whenever it decides to ask you something. stdout
/// is the protocol channel, so nothing else may ever be printed there (same
/// rule as the hook script); diagnostics go to stderr.
///
/// `tools/call` blocks until you answer, so it runs on its own thread. That way
/// `ping` and `notifications/cancelled` are still handled while it waits.
public final class MCPServer {
    public static let protocolVersion = "2025-06-18"

    /// Performs the actual ask (normally: POST /v1/ask to the app).
    public typealias Asker = (AskRequest, _ timeout: TimeInterval, CancelToken) -> AskResult

    public enum AskResult: Equatable {
        case answered(String)
        case noAnswer(String)     // reason
        case unavailable(String)  // the app isn't running, etc.
    }

    private let send: (Data) -> Void
    private let ask: Asker
    private let projectDir: String?
    private let lock = NSLock()
    private var inFlight: [String: CancelToken] = [:]   // JSON-RPC id (as text) -> token
    private(set) public var clientName: String?

    public init(projectDir: String?, send: @escaping (Data) -> Void, ask: @escaping Asker) {
        self.projectDir = projectDir
        self.send = send
        self.ask = ask
    }

    /// The agent name the app should show, from the client's self-reported name.
    public var agentName: String {
        let name = (clientName ?? "").lowercased()
        if name.contains("claude") { return "claude" }
        if name.contains("codex") { return "codex" }
        let cleaned = String(name.filter { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }.prefix(32))
        return cleaned.isEmpty ? "agent" : cleaned
    }

    /// Handle one line from stdin. Returns immediately; `tools/call` replies later.
    public func handle(line: Data) {
        guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            reply(error: -32700, "Parse error", id: NSNull())
            return
        }
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]                     // absent for notifications
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            clientName = (params["clientInfo"] as? [String: Any])?["name"] as? String
            reply(result: [
                "protocolVersion": (params["protocolVersion"] as? String) ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "nocnoc", "version": Router.version],
                "instructions": "Use ask_user to ask the human a question when you need their decision or input "
                    + "to continue, especially during long tasks when they may not be watching the chat. "
                    + "It shows a popup on their Mac and waits for the answer.",
            ], id: id)
        case "ping":
            reply(result: [:], id: id)
        case "tools/list":
            reply(result: ["tools": [Self.askUserTool]], id: id)
        case "tools/call":
            guard let id else { return }
            let name = params["name"] as? String
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard name == "ask_user" else {
                reply(error: -32602, "Unknown tool: \(name ?? "nil")", id: id)
                return
            }
            let token = CancelToken()
            lock.lock(); inFlight[Self.key(id)] = token; lock.unlock()
            Thread.detachNewThread { [self] in
                let result = callAskUser(args, token: token)
                lock.lock(); inFlight.removeValue(forKey: Self.key(id)); lock.unlock()
                if !token.isCancelled { reply(result: result, id: id) }   // no reply after a cancel
            }
        case "notifications/cancelled":
            if let rid = params["requestId"] {
                lock.lock(); let token = inFlight[Self.key(rid)]; lock.unlock()
                token?.cancel()
            }
        default:
            // Unknown notifications are ignored; unknown requests get an error.
            if let id { reply(error: -32601, "Method not found: \(method)", id: id) }
        }
    }

    /// Cancel everything (stdin closed: the agent went away).
    public func cancelAll() {
        lock.lock(); let tokens = Array(inFlight.values); lock.unlock()
        tokens.forEach { $0.cancel() }
    }

    // MARK: - ask_user

    public static let defaultTimeout: TimeInterval = 600
    public static let maxTimeout: TimeInterval = 3600

    static let askUserTool: [String: Any] = [
        "name": "ask_user",
        "title": "Ask the user",
        "description": "Ask the human user a question and wait for their answer, shown as a popup on their Mac "
            + "(nocnoc). Use it when you need a decision or information from them to continue, especially "
            + "during long tasks when they may not be watching the chat. Offer 2-6 short options when you can; "
            + "they can also type their own answer unless allow_free_text is false. Blocks until they answer or "
            + "timeout_seconds pass. If there is no answer, continue with your best judgement if it is safe, "
            + "or ask in the chat.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "question": ["type": "string", "description": "The question, one or two sentences."],
                "options": ["type": "array", "items": ["type": "string"], "maxItems": 8,
                            "description": "Short answer choices. Omit for a free-text question."],
                "multi_select": ["type": "boolean", "description": "Allow choosing several options. Default false."],
                "allow_free_text": ["type": "boolean", "description": "Allow a typed answer besides the options. Default true."],
                "context": ["type": "string", "description": "Optional background shown above the question."],
                "timeout_seconds": ["type": "integer", "minimum": 10, "maximum": 3600,
                                    "description": "How long to wait for an answer. Default 600."],
            ],
            "required": ["question"],
        ],
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
    ]

    func callAskUser(_ args: [String: Any], token: CancelToken) -> [String: Any] {
        guard let question = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else {
            return Self.toolResult("ask_user needs a non-empty \"question\".", isError: true)
        }
        let timeout = min(max((args["timeout_seconds"] as? NSNumber)?.doubleValue ?? Self.defaultTimeout, 10),
                          Self.maxTimeout)
        let request = AskRequest(agent: agentName, question: question,
                                 options: (args["options"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty },
                                 multiSelect: args["multi_select"] as? Bool,
                                 allowFreeText: args["allow_free_text"] as? Bool,
                                 context: args["context"] as? String,
                                 projectDir: projectDir)
        switch ask(request, timeout, token) {
        case .answered(let answer):
            return Self.toolResult("The user answered: \(answer)", structured: ["status": "answered", "answer": answer])
        case .noAnswer(let reason):
            return Self.toolResult("No answer from the user (\(reason)). They may be away. Continue with your best "
                                   + "judgement if it is safe, or ask again in the chat.",
                                   structured: ["status": "no_answer", "reason": reason])
        case .unavailable(let reason):
            return Self.toolResult("Could not reach the user through nocnoc (\(reason)). Ask in the chat instead.",
                                   isError: true)
        }
    }

    static func toolResult(_ text: String, isError: Bool = false, structured: [String: Any]? = nil) -> [String: Any] {
        var r: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
        if let structured { r["structuredContent"] = structured }
        return r
    }

    // MARK: - JSON-RPC plumbing

    private static func key(_ id: Any) -> String { "\(id)" }

    private func reply(result: [String: Any], id: Any?) {
        guard let id else { return }
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(error code: Int, _ message: String, id: Any) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        send(data)
    }
}

/// The real asker: POST /v1/ask to the running app and wait.
public enum AppAsker {
    public static func make(socketPath: String) -> MCPServer.Asker {
        return { request, timeout, token in
            guard let body = try? JSONEncoder().encode(request) else { return .unavailable("could not encode") }
            do {
                let (status, data) = try UnixSocketClient.request(
                    socketPath: socketPath, method: "POST", path: "/v1/ask",
                    headers: ["Content-Type": "application/json", "X-Nocnoc-Wait": "\(Int(timeout))"],
                    body: body, timeout: timeout + 5, cancel: token)
                guard status == 200, let resp = try? JSONDecoder().decode(AskResponse.self, from: data) else {
                    return .unavailable("app replied \(status)")
                }
                switch resp.status {
                case .answered: return .answered(resp.answer ?? "")
                case .noAnswer: return .noAnswer(resp.reason ?? "no answer")
                }
            } catch UnixSocketClient.ClientError.notRunning {
                return .unavailable("the nocnoc app is not running")
            } catch UnixSocketClient.ClientError.cancelled {
                return .noAnswer("cancelled")
            } catch UnixSocketClient.ClientError.timedOut {
                return .noAnswer("timed out")
            } catch {
                return .unavailable("\(error)")
            }
        }
    }
}
