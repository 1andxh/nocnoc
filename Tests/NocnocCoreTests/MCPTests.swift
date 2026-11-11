import XCTest
@testable import NocnocCore

/// Phase 5: the stdio MCP server and POST /v1/ask.
final class MCPTests: XCTestCase {
    /// Collects what the server writes to stdout.
    final class Out {
        private let lock = NSLock()
        private var lines: [[String: Any]] = []
        func add(_ d: Data) { lock.lock(); lines.append(try! JSONSerialization.jsonObject(with: d) as! [String: Any]); lock.unlock() }
        var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return lines }
        func waitFor(id: Int, timeout: TimeInterval = 3) -> [String: Any]? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if let m = all.first(where: { ($0["id"] as? Int) == id }) { return m }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return nil
        }
    }

    private func server(_ ask: @escaping MCPServer.Asker) -> (MCPServer, Out) {
        let out = Out()
        return (MCPServer(projectDir: "/p", send: out.add, ask: ask), out)
    }

    private func send(_ s: MCPServer, _ obj: [String: Any]) {
        s.handle(line: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func call(_ id: Int, _ args: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": "ask_user", "arguments": args]]
    }

    func testInitializeAndToolsList() throws {
        let (s, out) = server { _, _, _ in .answered("x") }
        send(s, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code", "version": "2.1"]]])
        let initResult = try XCTUnwrap(out.waitFor(id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(initResult["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((initResult["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual(s.agentName, "claude")

        send(s, ["jsonrpc": "2.0", "method": "notifications/initialized"])   // notification: no reply
        send(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try XCTUnwrap((out.waitFor(id: 2)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["ask_user"])
        XCTAssertEqual(((tools[0]["inputSchema"] as? [String: Any])?["required"] as? [String]), ["question"])
        XCTAssertEqual(out.all.count, 2, "notifications must not get a reply")
    }

    func testAnsweredCallPassesArgumentsThrough() throws {
        var seen: AskRequest?
        var seenTimeout: TimeInterval = 0
        let (s, out) = server { req, timeout, _ in seen = req; seenTimeout = timeout; return .answered("Postgres") }
        send(s, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex-mcp-client"]]])
        send(s, call(7, ["question": "Which DB?", "options": ["Postgres", "SQLite"], "timeout_seconds": 120]))
        let result = try XCTUnwrap(out.waitFor(id: 7)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"]) as? String
        XCTAssertEqual(text, "The user answered: Postgres")
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["answer"] as? String, "Postgres")
        XCTAssertEqual(seen?.agent, "codex")
        XCTAssertEqual(seen?.options, ["Postgres", "SQLite"])
        XCTAssertEqual(seen?.projectDir, "/p")
        XCTAssertEqual(seenTimeout, 120)
    }

    func testTimeoutIsClamped() throws {
        var seenTimeout: TimeInterval = 0
        let (s, out) = server { _, t, _ in seenTimeout = t; return .answered("ok") }
        send(s, call(1, ["question": "Q", "timeout_seconds": 99999]))
        _ = out.waitFor(id: 1)
        XCTAssertEqual(seenTimeout, MCPServer.maxTimeout)
    }

    func testNoAnswerAndUnavailable() throws {
        let (s1, o1) = server { _, _, _ in .noAnswer("timed out") }
        send(s1, call(1, ["question": "Q"]))
        let r1 = try XCTUnwrap(o1.waitFor(id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(r1["isError"] as? Bool, false)
        XCTAssertEqual((r1["structuredContent"] as? [String: Any])?["status"] as? String, "no_answer")

        let (s2, o2) = server { _, _, _ in .unavailable("the nocnoc app is not running") }
        send(s2, call(1, ["question": "Q"]))
        let r2 = try XCTUnwrap(o2.waitFor(id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(r2["isError"] as? Bool, true)
    }

    func testEmptyQuestionAndUnknownToolAndMethod() throws {
        let (s, out) = server { _, _, _ in XCTFail("must not ask"); return .answered("") }
        send(s, call(1, ["question": "   "]))
        XCTAssertEqual((out.waitFor(id: 1)?["result"] as? [String: Any])?["isError"] as? Bool, true)
        send(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "rm_rf"]])
        XCTAssertEqual((out.waitFor(id: 2)?["error"] as? [String: Any])?["code"] as? Int, -32602)
        send(s, ["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        XCTAssertEqual((out.waitFor(id: 3)?["error"] as? [String: Any])?["code"] as? Int, -32601)
        s.handle(line: Data("not json".utf8))
        XCTAssertTrue(out.all.contains { (($0["error"] as? [String: Any])?["code"] as? Int) == -32700 })
    }

    func testPingWorksWhileACallIsWaiting() throws {
        let release = DispatchSemaphore(value: 0)
        let (s, out) = server { _, _, _ in release.wait(); return .answered("late") }
        send(s, call(1, ["question": "Q"]))
        send(s, ["jsonrpc": "2.0", "id": 2, "method": "ping"])
        XCTAssertNotNil(out.waitFor(id: 2), "ping must not be stuck behind the waiting call")
        release.signal()
        XCTAssertNotNil(out.waitFor(id: 1))
    }
}

/// /v1/ask over a real socket, through the real client — what nocnoc-mcp does.
final class AskSocketTests: XCTestCase {
    private var dir: String!
    override func setUp() { dir = "/tmp/nocnoc-ask-\(getpid())-\(UInt32.random(in: 0...UInt32.max))" }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func start(onPending: @escaping (PendingRequests, PendingRequest) -> Void,
                       onResolved: @escaping (Outcome) -> Void = { _ in }, away: Bool = false) throws -> (UnixSocketServer, Router) {
        let pending = PendingRequests()
        let router = Router(store: EventStore(), pending: pending, isAway: { away },
                            onPending: { r in DispatchQueue.global().async { onPending(pending, r) } },
                            onResolved: { _, o in onResolved(o) }, holdMargin: 0)
        let server = UnixSocketServer(path: dir + "/t.sock", handler: router.handle)
        try server.start()
        return (server, router)
    }

    func testAnswerReachesTheAskerEvenWithAwayOff() throws {
        var event: AgentEvent?
        let (server, _) = try start(onPending: { p, r in
            event = r.event
            p.resolve(r.id, .answered(["Which DB?": "SQLite"]))
        }, away: false)
        defer { server.stop() }
        let asker = AppAsker.make(socketPath: dir + "/t.sock")
        let result = asker(AskRequest(agent: "claude", question: "Which DB?", options: ["Postgres", "SQLite"],
                                      context: "Picking storage for the cache", projectDir: "/tmp"), 30, CancelToken())
        XCTAssertEqual(result, .answered("SQLite"))
        XCTAssertEqual(event?.kind, .question)
        XCTAssertEqual(event?.title, "Claude asks you")
        XCTAssertEqual(event?.questions?.first?.context, "Picking storage for the cache")
        XCTAssertEqual(event?.questions?.first?.offersOther, true)
    }

    func testCancelWithdrawsTheQuestion() throws {
        let resolved = expectation(description: "withdrawn")
        var outcome: Outcome?
        let (server, _) = try start(onPending: { _, _ in }, onResolved: { o in outcome = o; resolved.fulfill() })
        defer { server.stop() }
        let token = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { token.cancel() }
        let result = AppAsker.make(socketPath: dir + "/t.sock")(AskRequest(question: "Q"), 30, token)
        XCTAssertEqual(result, .noAnswer("cancelled"))
        wait(for: [resolved], timeout: 3)
        XCTAssertEqual(outcome, .withdrawn)
    }

    func testAppNotRunning() {
        let result = AppAsker.make(socketPath: dir + "/nope.sock")(AskRequest(question: "Q"), 5, CancelToken())
        XCTAssertEqual(result, .unavailable("the nocnoc app is not running"))
    }

    func testFreeTextOnlyQuestionAlwaysOffersOther() {
        let e = AgentEvent.fromAsk(AskRequest(question: "Name?", options: [], allowFreeText: false), projectDirHint: nil)
        XCTAssertEqual(e.questions?.first?.offersOther, true, "no options: free text is the only way to answer")
    }
}
