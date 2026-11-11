import XCTest
@testable import NocnocCore

/// Phase 4: answering AskUserQuestion. Payload shape from the real lunch
/// question recorded in Phase 0 (spike/hooks.log, 2026-11-11).
final class QuestionTests: XCTestCase {
    private let lunch = """
    {"session_id":"s","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion",
     "tool_input":{"questions":[
       {"question":"What are you having for lunch today?","header":"Lunch","multiSelect":false,
        "options":[{"label":"Sandwich","description":"Quick"},{"label":"Rice dish","description":"Jollof"}]},
       {"question":"Which drinks?","header":"Drinks","multiSelect":true,
        "options":[{"label":"Water"},{"label":"Tea"},{"label":"Juice"}]}]}}
    """

    private func post(_ body: String) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/v1/hooks/claude",
                    headers: ["x-nocnoc-wait": "30"], body: Data(body.utf8))
    }

    private func router(_ answer: @escaping (PendingRequests, PendingRequest) -> Void) -> Router {
        let pending = PendingRequests()
        return Router(store: EventStore(), pending: pending, isAway: { true },
                      onPending: { r in DispatchQueue.global().async { answer(pending, r) } }, holdMargin: 0)
    }

    func testParsesQuestions() throws {
        let e = try XCTUnwrap(AgentEvent.fromHookPayload(Data(lunch.utf8), agent: "claude", projectDirHint: nil))
        XCTAssertEqual(e.kind, .question)
        XCTAssertTrue(e.isAnswerable)
        XCTAssertEqual(e.questions?.count, 2)
        XCTAssertEqual(e.questions?[0].options.map(\.label), ["Sandwich", "Rice dish"])
        XCTAssertEqual(e.questions?[1].multiSelect, true)
        XCTAssertNil(e.questions?[1].options[0].description)
    }

    func testAnsweredQuestionReturnsOriginalInputPlusAnswers() throws {
        let answers = ["What are you having for lunch today?": "Rice dish", "Which drinks?": "Water, Juice"]
        let r = router { p, req in p.resolve(req.id, .answered(answers)) }
        let resp = r.handle(post(lunch))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: resp.body) as? [String: Any])
        let out = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(out["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(out["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], answers)
        // the original questions must be echoed back unchanged
        let qs = try XCTUnwrap(updated["questions"] as? [[String: Any]])
        XCTAssertEqual(qs.count, 2)
        XCTAssertEqual(qs[0]["header"] as? String, "Lunch")
    }

    func testIncompleteAnswersAreNotSent() {
        let r = router { p, req in p.resolve(req.id, .answered(["What are you having for lunch today?": "Sandwich"])) }
        XCTAssertEqual(r.handle(post(lunch)), .noDecision, "one of two questions unanswered: let Claude ask")
    }

    func testBlankAnswerCountsAsUnanswered() {
        XCTAssertFalse(QuestionReply.isComplete(["Q": "   "], for: [.init(question: "Q", header: nil, options: [], multiSelect: nil)]))
    }

    func testPlainAllowOnAQuestionIsNeverSent() {
        // Claude docs: "allow" alone is not sufficient for AskUserQuestion.
        let r = router { p, req in p.resolve(req.id, .decided(.allow)) }
        XCTAssertEqual(r.handle(post(lunch)), .noDecision)
    }

    func testReleasedQuestionMeansNoDecision() {
        let r = router { p, req in p.resolve(req.id, .released) }
        XCTAssertEqual(r.handle(post(lunch)), .noDecision)
    }

    func testMultiSelectJoinKeepsOfferedOrder() {
        let q = AgentEvent.Question(question: "Which drinks?", header: nil,
                                    options: [.init(label: "Water", description: nil), .init(label: "Tea", description: nil),
                                              .init(label: "Juice", description: nil)], multiSelect: true)
        XCTAssertEqual(QuestionReply.join(["Juice", "Water"], in: q), "Water, Juice")
    }
}
