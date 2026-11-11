import XCTest
@testable import NocnocCore

final class AgentEventTests: XCTestCase {
    private func event(_ json: String, hint: String? = nil) -> AgentEvent? {
        AgentEvent.fromHookPayload(Data(json.utf8), agent: "claude", projectDirHint: hint)
    }

    /// Shape copied from a real PermissionRequest recorded in Phase 0
    /// (spike/hooks.log, 2026-11-11), with ids shortened.
    func testAskUserQuestionFromRealPayload() throws {
        let json = """
        {"session_id":"s1","cwd":"/Users/mac/dev/nocnoc","permission_mode":"auto",
         "hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion",
         "tool_input":{"questions":[{"question":"What are you having for lunch today?","header":"Lunch",
           "options":[{"label":"Sandwich","description":"Quick"},{"label":"Rice dish","description":"Jollof"}],
           "multiSelect":false}]}}
        """
        let e = try XCTUnwrap(event(json))
        XCTAssertEqual(e.title, "Claude has a question")
        XCTAssertEqual(e.body, "What are you having for lunch today?\nSandwich · Rice dish")
        XCTAssertEqual(e.sessionID, "s1")
        XCTAssertEqual(e.project, "nocnoc")
        XCTAssertTrue(e.shouldNotify)
    }

    func testBashPermissionShowsCommand() throws {
        let e = try XCTUnwrap(event("""
        {"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build/"}}
        """))
        XCTAssertEqual(e.title, "Claude needs permission")
        XCTAssertEqual(e.body, "Bash: rm -rf build/")
    }

    func testEditPermissionShowsPathRelativeToCwd() throws {
        let e = try XCTUnwrap(event("""
        {"hook_event_name":"PermissionRequest","cwd":"/p","tool_name":"Edit","tool_input":{"file_path":"/p/src/a.swift"}}
        """))
        XCTAssertEqual(e.body, "Edit: src/a.swift")
    }

    func testProjectDirHintBeatsCwd() throws {
        // Claude may have cd'd into a subfolder; $CLAUDE_PROJECT_DIR (sent as a header) is the real root.
        let e = try XCTUnwrap(event(#"{"hook_event_name":"Stop","cwd":"/p/backend"}"#, hint: "/p"))
        XCTAssertEqual(e.projectDir, "/p")
        let noHint = try XCTUnwrap(event(#"{"hook_event_name":"Stop","cwd":"/p/backend"}"#, hint: ""))
        XCTAssertEqual(noHint.projectDir, "/p/backend")
    }

    func testStopAndNotification() throws {
        let stop = try XCTUnwrap(event(#"{"hook_event_name":"Stop"}"#))
        XCTAssertEqual(stop.title, "Claude finished")
        XCTAssertEqual(stop.body, "Ready for your next message")

        let note = try XCTUnwrap(event(#"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#))
        XCTAssertEqual(note.title, "Claude needs you")
        XCTAssertEqual(note.body, "Claude is waiting for your input")
    }

    func testUnknownEventIsRecordedButNotNotified() throws {
        let e = try XCTUnwrap(event(#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#))
        XCTAssertFalse(e.shouldNotify)
    }

    func testLongBodyIsTruncated() throws {
        let long = String(repeating: "x", count: 1000)
        let e = try XCTUnwrap(event(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"\#(long)"}}"#))
        XCTAssertEqual(e.body.count, AgentEvent.maxBodyLength)
        XCTAssertTrue(e.body.hasSuffix("…"))
    }

    func testNonObjectJSONIsRejected() {
        XCTAssertNil(event("[1,2]"))
        XCTAssertNil(event("not json"))
    }
}

final class ActivityEventTests: XCTestCase {
    func testActivityEventsAreNotShownOrStored() throws {
        let store = EventStore()
        var seen: [AgentEvent] = []
        let router = Router(store: store, isAway: { true }, onEvent: { seen.append($0) })
        for name in ["PostToolUse", "PostToolUseFailure", "PermissionDenied", "UserPromptSubmit"] {
            let body = #"{"hook_event_name":"\#(name)","session_id":"s","tool_name":"Bash"}"#
            let resp = router.handle(HTTPRequest(method: "POST", path: "/v1/hooks/claude", body: Data(body.utf8)))
            XCTAssertEqual(resp, .noDecision)
        }
        XCTAssertEqual(seen.map(\.kind), Array(repeating: .activity, count: 4), "app still hears them, to clear notifications")
        XCTAssertTrue(seen.allSatisfy { !$0.shouldNotify })
        XCTAssertTrue(store.all.isEmpty, "they must not flood the recent list")
    }
}
