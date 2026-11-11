import Foundation

/// One thing an agent told us, already turned into something a human can read.
public struct AgentEvent: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable {
        case permission   // wants to run a tool; can be answered allow/deny (Phase 2)
        case question     // AskUserQuestion; answered from the floating panel (Phase 4)
        case attention    // Notification hook: "needs you"
        case finished     // Stop hook
        case activity     // the session moved on (tool ran, prompt submitted, permission denied):
                          // used to clear a stale "needs you" notification, never shown
        case other
    }

    /// One AskUserQuestion question, as Claude sends it.
    public struct Question: Codable, Equatable {
        public struct Option: Codable, Equatable {
            public let label: String
            public let description: String?
        }
        public let question: String
        public let header: String?
        public let options: [Option]
        public let multiSelect: Bool?
        /// ask_user only (Claude's AskUserQuestion always allows "Other"):
        public let allowsOther: Bool?
        public let context: String?

        public init(question: String, header: String?, options: [Option], multiSelect: Bool?,
                    allowsOther: Bool? = nil, context: String? = nil) {
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
            self.allowsOther = allowsOther
            self.context = context
        }

        /// Free text is offered unless switched off — and always when there are no options.
        public var offersOther: Bool { allowsOther != false || options.isEmpty }
    }

    public let id: UUID
    public let at: Date
    public let agent: String          // "claude", "codex", ...
    public let hookEvent: String      // hook_event_name, e.g. "PermissionRequest"
    public let kind: Kind
    public let toolName: String?
    public let sessionID: String?
    public let projectDir: String?    // where the agent's project lives (for focusing the editor)
    public let title: String          // e.g. "Claude needs permission"
    public let body: String           // short, fits a notification
    public let detail: String         // full text (up to maxDetailLength), for the menu
    public let detailIsTruncated: Bool // even `detail` couldn't hold all of it
    public let shouldNotify: Bool
    /// Parsed questions, for kind == .question.
    public let questions: [Question]?
    /// The tool's original input JSON. Answering a question means sending it
    /// back unchanged plus an `answers` object.
    public let toolInput: Data?

    public var project: String? {
        projectDir.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// True when the notification body had to cut text off. We never offer
    /// "Allow" on a notification that doesn't show the whole command.
    public var bodyIsTruncated: Bool { body != detail }

    /// What nocnoc can answer: permission prompts, and questions we could parse.
    public var isAnswerable: Bool {
        switch kind {
        case .permission: return true
        case .question: return !(questions ?? []).isEmpty && toolInput != nil
        default: return false
        }
    }

    public init(id: UUID = UUID(), at: Date = Date(), agent: String, hookEvent: String, kind: Kind = .other,
                toolName: String? = nil, sessionID: String?, projectDir: String?, title: String, body: String,
                detail: String? = nil, detailIsTruncated: Bool = false, shouldNotify: Bool,
                questions: [Question]? = nil, toolInput: Data? = nil) {
        self.id = id
        self.at = at
        self.agent = agent
        self.hookEvent = hookEvent
        self.kind = kind
        self.toolName = toolName
        self.sessionID = sessionID
        self.projectDir = projectDir
        self.title = title
        self.body = body
        self.detail = detail ?? body
        self.detailIsTruncated = detailIsTruncated
        self.shouldNotify = shouldNotify
        self.questions = questions
        self.toolInput = toolInput
    }

    public static let maxBodyLength = 240
    public static let maxDetailLength = 4000

    /// Build an event from a hook's stdin JSON.
    ///
    /// Field names are from the real payloads recorded in Phase 0
    /// (spike/hooks.log) plus the Claude Code hooks docs. Anything we don't
    /// recognise still becomes an event, just without a notification.
    public static func fromHookPayload(_ data: Data, agent: String, projectDirHint: String?,
                                       isDirectory: (String) -> Bool = AgentEvent.directoryExists) -> AgentEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let name = displayName(agent)
        let hookEvent = obj["hook_event_name"] as? String ?? "unknown"
        let cwd = obj["cwd"] as? String
        // Claude sends its project root (we pass $CLAUDE_PROJECT_DIR as a header).
        // Codex doesn't, so walk up from cwd to the git root, else use cwd.
        let projectDir = (projectDirHint?.isEmpty == false ? projectDirHint : nil)
            ?? cwd.map { gitRoot(of: $0, isDirectory: isDirectory) ?? $0 }
        let toolName = obj["tool_name"] as? String
        let toolInput = obj["tool_input"] as? [String: Any] ?? [:]

        let kind: Kind
        let title: String
        let text: String
        var short: String? = nil   // notification text, when it differs from the full text
        var questions: [Question]? = nil

        switch hookEvent {
        case "PermissionRequest" where toolName == "AskUserQuestion":
            kind = .question
            title = "\(name) has a question"
            text = summarizeQuestions(toolInput)
            questions = parseQuestions(toolInput)
        case "PermissionRequest":
            kind = .permission
            title = "\(name) needs permission"
            text = summarizeTool(toolName ?? "a tool", toolInput, cwd: cwd)
            short = patchSummary(toolName, toolInput)
        case "Notification":
            kind = .attention
            title = "\(name) needs you"
            text = (obj["message"] as? String) ?? (obj["notification_type"] as? String) ?? "Waiting for your input"
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied", "UserPromptSubmit":
            kind = .activity
            title = "\(name): \(hookEvent)"
            text = toolName ?? ""
        case "Stop":
            kind = .finished
            title = "\(name) finished"
            text = (obj["last_assistant_message"] as? String) ?? "Ready for your next message"
        default:
            kind = .other
            title = "\(name): \(hookEvent)"
            text = toolName ?? ""
        }

        return AgentEvent(agent: agent, hookEvent: hookEvent, kind: kind, toolName: toolName,
                          sessionID: obj["session_id"] as? String, projectDir: projectDir, title: title,
                          body: truncate(short ?? text, to: maxBodyLength), detail: truncate(text, to: maxDetailLength),
                          detailIsTruncated: text.count > maxDetailLength,
                          shouldNotify: kind != .other && kind != .activity,
                          questions: questions,
                          toolInput: obj["tool_input"].flatMap { try? JSONSerialization.data(withJSONObject: $0) })
    }

    /// An `ask_user` call from the MCP server: the agent chose to ask you something.
    public static func fromAsk(_ ask: AskRequest, projectDirHint: String?,
                               isDirectory: (String) -> Bool = AgentEvent.directoryExists) -> AgentEvent {
        let agent = ask.agent.flatMap { Router.isValidAgentName($0) ? $0 : nil } ?? "agent"
        let dir = (projectDirHint?.isEmpty == false ? projectDirHint : nil) ?? ask.projectDir
        let projectDir = dir.map { gitRoot(of: $0, isDirectory: isDirectory) ?? $0 }
        let question = Question(question: ask.question, header: nil,
                                options: (ask.options ?? []).map { .init(label: $0, description: nil) },
                                multiSelect: ask.multiSelect, allowsOther: ask.allowFreeText, context: ask.context)
        let text = summarizeQuestions(["questions": [["question": ask.question,
                                                      "options": (ask.options ?? []).map { ["label": $0] }]]])
        return AgentEvent(agent: agent, hookEvent: "ask_user", kind: .question, toolName: "ask_user",
                          sessionID: nil, projectDir: projectDir, title: "\(displayName(agent)) asks you",
                          body: truncate(text, to: maxBodyLength), detail: truncate(text, to: maxDetailLength),
                          shouldNotify: true, questions: [question])
    }

    static func displayName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }

    static func summarizeQuestions(_ input: [String: Any]) -> String {
        guard let questions = input["questions"] as? [[String: Any]], let first = questions.first else {
            return "Open VS Code to answer"
        }
        let text = first["question"] as? String ?? "Question"
        let labels = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        var out = labels.isEmpty ? text : "\(text)\n\(labels.joined(separator: " · "))"
        if questions.count > 1 { out += "\n(+\(questions.count - 1) more)" }
        return out
    }

    static func parseQuestions(_ input: [String: Any]) -> [Question]? {
        guard let raw = input["questions"],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let qs = try? JSONDecoder().decode([Question].self, from: data),
              !qs.isEmpty else { return nil }
        return qs
    }

    static func summarizeTool(_ tool: String, _ input: [String: Any], cwd: String?) -> String {
        if let command = input["command"] as? String {
            // Codex adds a plain-English description of what the command is for.
            if let why = input["description"] as? String, !why.isEmpty { return "\(tool): \(command)\n\(why)" }
            return "\(tool): \(command)"
        }
        if let file = input["file_path"] as? String { return "\(tool): \(relative(file, to: cwd))" }
        if let url = input["url"] as? String { return "\(tool): \(url)" }
        if input.isEmpty { return tool }
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return "\(tool): \(json)"
    }

    /// Codex sends file edits as a patch in tool_input.command. A patch never
    /// fits a notification, so the notification lists the files instead and
    /// (because that differs from the full text) only offers Deny.
    static func patchSummary(_ tool: String?, _ input: [String: Any]) -> String? {
        guard let patch = input["command"] as? String, patch.contains("*** Begin Patch") else { return nil }
        let verbs = ["*** Add File: ": "add", "*** Update File: ": "edit", "*** Delete File: ": "delete"]
        var files: [String] = []
        for line in patch.split(separator: "\n") {
            for (prefix, verb) in verbs where line.hasPrefix(prefix) {
                files.append("\(verb) \(line.dropFirst(prefix.count))")
            }
        }
        let what = files.isEmpty ? "a patch" : files.joined(separator: ", ")
        return "\(tool ?? "apply_patch"): \(what)"
    }

    public static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Nearest ancestor of `path` (inclusive) that contains a `.git` directory.
    static func gitRoot(of path: String, isDirectory: (String) -> Bool) -> String? {
        var dir = URL(fileURLWithPath: path).standardizedFileURL.path
        while true {
            if isDirectory(dir + "/.git") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }

    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }

    static func truncate(_ s: String, to limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }
}
