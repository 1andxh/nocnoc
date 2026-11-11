import XCTest
@testable import NocnocCore

/// Phase 3: Codex. The Stop payload is copied from a real `codex exec` run
/// (codex-cli 0.167, 2026-11-11, ids shortened). The PermissionRequest shape is
/// from the Codex hooks docs; real capture is pending (see README).
final class CodexTests: XCTestCase {
    private func event(_ json: String, isDirectory: @escaping (String) -> Bool = { _ in false }) -> AgentEvent? {
        AgentEvent.fromHookPayload(Data(json.utf8), agent: "codex", projectDirHint: "", isDirectory: isDirectory)
    }

    func testRealStopPayload() throws {
        let json = """
        {"session_id":"s","turn_id":"t","transcript_path":"/x.jsonl","cwd":"/Users/mac/dev/nocnoc",
         "hook_event_name":"Stop","model":"gpt-6-luna","permission_mode":"bypassPermissions",
         "stop_hook_active":false,"last_assistant_message":"I can’t run that command: the active environment is read-only."}
        """
        let e = try XCTUnwrap(event(json))
        XCTAssertEqual(e.title, "Codex finished")
        XCTAssertEqual(e.body, "I can’t run that command: the active environment is read-only.")
        XCTAssertEqual(e.kind, .finished)
    }

    func testBashPermissionIncludesDescription() throws {
        let e = try XCTUnwrap(event("""
        {"hook_event_name":"PermissionRequest","turn_id":"t","cwd":"/p","tool_name":"Bash",
         "tool_input":{"command":"touch /tmp/x","description":"Create a marker file outside the sandbox"}}
        """))
        XCTAssertEqual(e.title, "Codex needs permission")
        XCTAssertEqual(e.body, "Bash: touch /tmp/x\nCreate a marker file outside the sandbox")
        XCTAssertFalse(e.bodyIsTruncated, "short command + description: Allow can be offered")
        XCTAssertTrue(e.isAnswerable)
    }

    func testNullDescriptionIsIgnored() throws {
        let e = try XCTUnwrap(event(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls","description":null}}"#))
        XCTAssertEqual(e.body, "Bash: ls")
    }

    func testApplyPatchListsFilesAndIsDenyOnlyOnNotification() throws {
        let patch = "*** Begin Patch\\n*** Update File: src/a.swift\\n@@\\n-old\\n+new\\n*** Add File: src/b.swift\\n+hello\\n*** Delete File: c.txt\\n*** End Patch"
        let e = try XCTUnwrap(event(#"{"hook_event_name":"PermissionRequest","tool_name":"apply_patch","tool_input":{"command":"\#(patch)"}}"#))
        XCTAssertEqual(e.body, "apply_patch: edit src/a.swift, add src/b.swift, delete c.txt")
        XCTAssertTrue(e.detail.contains("+new"), "full patch is kept for the menu")
        XCTAssertTrue(e.bodyIsTruncated, "notification shows a summary, so no Allow there")
        XCTAssertFalse(e.detailIsTruncated)
    }

    func testHugeCommandIsTooLongEvenForTheMenu() throws {
        let big = String(repeating: "y", count: AgentEvent.maxDetailLength + 10)
        let e = try XCTUnwrap(event(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"\#(big)"}}"#))
        XCTAssertTrue(e.detailIsTruncated)
    }

    func testProjectDirFallsBackToGitRootOfCwd() throws {
        // Codex sends no project dir; cwd may be a subfolder.
        let e = try XCTUnwrap(event(#"{"hook_event_name":"Stop","cwd":"/repo/backend/app"}"#,
                                    isDirectory: { $0 == "/repo/.git" }))
        XCTAssertEqual(e.projectDir, "/repo")
        let noGit = try XCTUnwrap(event(#"{"hook_event_name":"Stop","cwd":"/tmp/scratch"}"#))
        XCTAssertEqual(noGit.projectDir, "/tmp/scratch")
    }

    func testAllowReplyShapeMatchesCodexDocs() throws {
        // Codex: hookSpecificOutput.hookEventName = "PermissionRequest", decision.behavior,
        // deny carries a message; must NOT include updatedInput/updatedPermissions/interrupt.
        let allow = try JSONSerialization.jsonObject(with: HTTPResponse.json(PermissionReply(.allow)).body) as! [String: Any]
        let out = allow["hookSpecificOutput"] as! [String: Any]
        let decision = out["decision"] as! [String: Any]
        XCTAssertEqual(out["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(Set(decision.keys), ["behavior"])
        let deny = try JSONSerialization.jsonObject(with: HTTPResponse.json(PermissionReply(.deny)).body) as! [String: Any]
        let dd = (deny["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        XCTAssertEqual(Set(dd.keys), ["behavior", "message"])
    }
}
