import XCTest
import Darwin
@testable import NocnocCore

/// Phase 2: permission requests held open until the user answers.
/// One test per row of the failure table in PLAN.md §3.
final class HoldTests: XCTestCase {
    private let bash = #"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"rm -rf build/"}}"#

    private func post(_ body: String, wait: Int?) -> HTTPRequest {
        var headers = ["content-length": "\(body.utf8.count)"]
        if let wait { headers["x-nocnoc-wait"] = "\(wait)" }
        return HTTPRequest(method: "POST", path: "/v1/hooks/claude", headers: headers, body: Data(body.utf8))
    }

    /// Router whose onPending hands each held request to `answer`, on another thread,
    /// the way a click arrives from the UI.
    private func router(away: Bool = true, holdMargin: TimeInterval = 0,
                        answer: ((PendingRequests, PendingRequest) -> Void)? = nil,
                        resolved: ((Outcome) -> Void)? = nil) -> Router {
        let pending = PendingRequests()
        return Router(store: EventStore(), pending: pending, isAway: { away },
                      onPending: { r in
                          if let answer { DispatchQueue.global().async { answer(pending, r) } }
                      },
                      onResolved: { _, o in resolved?(o) },
                      holdMargin: holdMargin)
    }

    private func reply(_ resp: HTTPResponse) throws -> PermissionReply {
        try JSONDecoder().decode(PermissionReply.self, from: resp.body)
    }

    func testAllowClickReturnsClaudeAllowJSON() throws {
        let r = router(answer: { p, req in p.resolve(req.id, .decided(.allow)) })
        let resp = r.handle(post(bash, wait: 30))
        let out = try reply(resp)
        XCTAssertEqual(out.hookSpecificOutput.hookEventName, "PermissionRequest")
        XCTAssertEqual(out.hookSpecificOutput.decision.behavior, "allow")
        XCTAssertNil(out.hookSpecificOutput.decision.message)
        // Exact wire format the hook will print:
        XCTAssertEqual(String(decoding: resp.body, as: UTF8.self),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
    }

    func testDenyClickReturnsDenyWithMessage() throws {
        let r = router(answer: { p, req in p.resolve(req.id, .decided(.deny)) })
        let out = try reply(r.handle(post(bash, wait: 30)))
        XCTAssertEqual(out.hookSpecificOutput.decision.behavior, "deny")
        XCTAssertEqual(out.hookSpecificOutput.decision.message, PermissionReply.denyMessage)
    }

    func testReleaseMeansNoDecision() {
        let r = router(answer: { p, req in p.resolve(req.id, .released) })
        XCTAssertEqual(r.handle(post(bash, wait: 30)), .noDecision)
    }

    func testTimeoutMeansNoDecision() {
        var outcome: Outcome?
        let start = Date()
        let r = router(holdMargin: 1, resolved: { outcome = $0 })   // wait 3 - margin 1 = hold 2s
        XCTAssertEqual(r.handle(post(bash, wait: 3)), .noDecision)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(Date().timeIntervalSince(start), 2, accuracy: 0.6)
    }

    func testAwayOffAnswersImmediately() {
        let r = router(away: false, answer: { _, _ in XCTFail("must not hold when Away is off") })
        XCTAssertEqual(r.handle(post(bash, wait: 30)), .noDecision)
    }

    func testNoWaitHeaderMeansNoHold() {
        let r = router(answer: { _, _ in XCTFail("must not hold without X-Nocnoc-Wait") })
        XCTAssertEqual(r.handle(post(bash, wait: nil)), .noDecision)
    }

    func testUnparseableQuestionsAreNotHeld() {
        let q = #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#
        let r = router(answer: { _, _ in XCTFail("no parsed questions: nothing to answer, must not hold") })
        XCTAssertEqual(r.handle(post(q, wait: 30)), .noDecision)
    }

    func testFirstAnswerWinsLaterOnesIgnored() throws {
        let r = router(answer: { p, req in
            XCTAssertTrue(p.resolve(req.id, .decided(.deny)))
            XCTAssertFalse(p.resolve(req.id, .decided(.allow)), "second click must be ignored")
        })
        XCTAssertEqual(try reply(r.handle(post(bash, wait: 30))).hookSpecificOutput.decision.behavior, "deny")
    }

    func testClientHangUpWithdrawsRequest() {
        var connected = true
        var outcome: Outcome?
        let pending = PendingRequests()
        let r = Router(store: EventStore(), pending: pending, isAway: { true },
                       onPending: { _ in DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { connected = false } },
                       onResolved: { _, o in outcome = o }, holdMargin: 0)
        XCTAssertEqual(r.handle(post(bash, wait: 30), ConnectionContext(isConnected: { connected })), .noDecision)
        XCTAssertEqual(outcome, .withdrawn)
        XCTAssertTrue(pending.all.isEmpty)
    }

    func testResolveAllReleasesEverything() {
        let pending = PendingRequests()
        let e = AgentEvent(agent: "claude", hookEvent: "PermissionRequest", kind: .permission,
                           sessionID: nil, projectDir: nil, title: "t", body: "b", shouldNotify: true)
        _ = pending.add(e, deadline: .distantFuture)
        _ = pending.add(e, deadline: .distantFuture)
        XCTAssertEqual(pending.resolveAll(.released), 2)
        XCTAssertTrue(pending.all.isEmpty)
    }

    func testTruncatedBodyIsFlagged() throws {
        let long = String(repeating: "x", count: 500)
        let e = try XCTUnwrap(AgentEvent.fromHookPayload(Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"\#(long)"}}"#.utf8), agent: "claude", projectDirHint: nil))
        XCTAssertTrue(e.bodyIsTruncated)
        XCTAssertEqual(e.detail, "Bash: " + long)
    }
}

/// The same, over a real socket: when curl dies, the app must notice.
final class HoldSocketTests: XCTestCase {
    func testRealHangUpIsDetected() throws {
        let dir = "/tmp/nocnoc-hold-\(getpid())"
        let path = dir + "/t.sock"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let done = expectation(description: "resolved")
        var outcome: Outcome?
        let router = Router(store: EventStore(), isAway: { true },
                            onResolved: { _, o in outcome = o; done.fulfill() }, holdMargin: 0)
        let server = UnixSocketServer(path: path, handler: router.handle)
        try server.start()
        defer { server.stop() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        XCTAssertEqual(withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }, 0)
        let body = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let raw = "POST /v1/hooks/claude HTTP/1.1\r\nX-Nocnoc-Wait: 30\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = raw.withCString { write(fd, $0, strlen($0)) }

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(router.pending.all.count, 1, "request should be held")
        close(fd)   // the hook process dies

        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcome, .withdrawn)
    }
}
