import XCTest
@testable import NocnocCore

final class PresenceTests: XCTestCase {
    private func event(_ hookEvent: String) -> AgentEvent {
        AgentEvent(agent: "claude", hookEvent: hookEvent, kind: .permission, sessionID: "s",
                   projectDir: nil, title: "t", body: "b", shouldNotify: true)
    }

    func testEditorsAndTerminalsAreRecognised() {
        XCTAssertTrue(Presence.isEditor("com.microsoft.VSCode"))
        XCTAssertTrue(Presence.isEditor("com.apple.Terminal"))
        XCTAssertFalse(Presence.isEditor("com.apple.Safari"))
        XCTAssertFalse(Presence.isEditor(nil))
    }

    func testHookPromptsWaitWhileYoureInTheEditor() {
        let e = event("PermissionRequest")
        XCTAssertFalse(Presence.showsCard(for: e, editorFrontmost: true, quietInEditor: true))
        XCTAssertTrue(Presence.showsCard(for: e, editorFrontmost: false, quietInEditor: true))
        XCTAssertTrue(Presence.showsCard(for: e, editorFrontmost: true, quietInEditor: false), "setting off: always show")
    }

    func testAskUserAlwaysShows() {
        // No prompt for it in the editor: the card is the only way to answer.
        XCTAssertTrue(Presence.showsCard(for: event("ask_user"), editorFrontmost: true, quietInEditor: true))
    }

    func testNotificationsAreQuietInTheEditor() {
        XCTAssertFalse(Presence.notifies(editorFrontmost: true, quietInEditor: true))
        XCTAssertTrue(Presence.notifies(editorFrontmost: false, quietInEditor: true))
        XCTAssertTrue(Presence.notifies(editorFrontmost: true, quietInEditor: false))
    }
}
