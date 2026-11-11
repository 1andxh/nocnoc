import XCTest
@testable import NocnocCore

final class HTTPParserTests: XCTestCase {
    private func parse(_ s: String, max: Int = 1024) -> HTTPParseResult {
        HTTPParser.parse(Data(s.utf8), maxBodyBytes: max)
    }

    func testCompletePostWithBody() {
        let raw = "POST /v1/hooks/claude HTTP/1.1\r\nHost: nocnoc\r\nContent-Length: 2\r\nX-Nocnoc-Project-Dir: /p\r\n\r\n{}"
        guard case .complete(let req) = parse(raw) else { return XCTFail("expected complete") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/hooks/claude")
        XCTAssertEqual(req.headers["x-nocnoc-project-dir"], "/p")
        XCTAssertEqual(req.body, Data("{}".utf8))
    }

    func testQueryStringIsStrippedFromPath() {
        guard case .complete(let req) = parse("GET /v1/health?x=1 HTTP/1.1\r\n\r\n") else { return XCTFail() }
        XCTAssertEqual(req.path, "/v1/health")
    }

    func testIncompleteUntilWholeBodyArrives() {
        XCTAssertEqual(parse("POST /x HTTP/1.1\r\nContent-Length: 5\r\n"), .incomplete)        // headers not finished
        XCTAssertEqual(parse("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nabc"), .incomplete)  // body short
    }

    func testRejectsOversizedBody() {
        guard case .invalid(let status, _) = parse("POST /x HTTP/1.1\r\nContent-Length: 5000\r\n\r\n", max: 1024)
        else { return XCTFail() }
        XCTAssertEqual(status, 413)
    }

    func testRejectsChunked() {
        guard case .invalid(let status, _) = parse("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
        else { return XCTFail() }
        XCTAssertEqual(status, 411)
    }

    func testRejectsGarbageRequestLine() {
        guard case .invalid(let status, _) = parse("hello\r\n\r\n") else { return XCTFail() }
        XCTAssertEqual(status, 400)
    }

    func testRejectsHugeHeadersWithoutTerminator() {
        let raw = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPParser.maxHeaderBytes + 10)
        guard case .invalid(let status, _) = parse(raw) else { return XCTFail() }
        XCTAssertEqual(status, 431)
    }
}
