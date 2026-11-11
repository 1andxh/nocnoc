import XCTest
import Darwin
@testable import NocnocCore

/// End-to-end over a real unix socket: the same path the hook script's curl takes.
final class SocketServerTests: XCTestCase {
    private var dir: String!
    private var sockPath: String { dir + "/t.sock" }

    override func setUp() {
        // Short path: unix socket paths are limited to ~104 bytes.
        dir = "/tmp/nocnoc-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func makeServer(away: Bool = true, onEvent: @escaping (AgentEvent) -> Void = { _ in }) -> (UnixSocketServer, EventStore) {
        let store = EventStore()
        let router = Router(store: store, isAway: { away }, onEvent: onEvent)
        return (UnixSocketServer(path: sockPath, handler: router.handle), store)
    }

    /// Send raw bytes, read until the server closes, return the response text.
    private func roundTrip(_ raw: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(sockPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(rc, 0, "connect failed")
        _ = raw.withCString { write(fd, $0, strlen($0)) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }

    func testHealthOverSocket() throws {
        let (server, _) = makeServer()
        try server.start()
        defer { server.stop() }
        let resp = try roundTrip("GET /v1/health HTTP/1.1\r\nHost: nocnoc\r\n\r\n")
        XCTAssertTrue(resp.hasPrefix("HTTP/1.1 200 OK"), resp)
        XCTAssertTrue(resp.contains(#""away":true"#), resp)
    }

    func testHookPostRecordsEventAndReturnsEmptyBody() throws {
        var seen: [AgentEvent] = []
        let lock = NSLock()
        let (server, store) = makeServer(onEvent: { e in lock.lock(); seen.append(e); lock.unlock() })
        try server.start()
        defer { server.stop() }

        let body = #"{"hook_event_name":"Stop","session_id":"abc"}"#
        let resp = try roundTrip("POST /v1/hooks/claude HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")

        XCTAssertTrue(resp.hasPrefix("HTTP/1.1 200 OK"), resp)
        XCTAssertTrue(resp.hasSuffix("Content-Length: 0\r\nConnection: close\r\n\r\n"), "hook reply must be empty = no decision")
        XCTAssertEqual(store.all.first?.title, "Claude finished")
        lock.lock(); XCTAssertEqual(seen.count, 1); lock.unlock()
    }

    func testBadAgentNameAndBadJSON() throws {
        let (server, store) = makeServer()
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(try roundTrip("POST /v1/hooks/../x HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}").hasPrefix("HTTP/1.1 404"))
        XCTAssertTrue(try roundTrip("POST /v1/hooks/claude HTTP/1.1\r\nContent-Length: 3\r\n\r\nxyz").hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(store.all.isEmpty)
    }

    func testSocketAndDirectoryPermissions() throws {
        let (server, _) = makeServer()
        try server.start()
        defer { server.stop() }
        var st = stat()
        XCTAssertEqual(lstat(sockPath, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "socket must be owner-only")
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(lstat(dir, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "directory must be owner-only")
    }

    func testSecondServerOnSamePathRefusesToStart() throws {
        let (first, _) = makeServer()
        try first.start()
        defer { first.stop() }
        let (second, _) = makeServer()
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? UnixSocketServer.ServerError, .alreadyRunning(sockPath))
        }
    }

    func testStaleSocketFromCrashedRunIsReplaced() throws {
        // Simulate a crash: bind a socket, then close it without unlinking.
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(sockPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath))

        let (server, _) = makeServer()
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        XCTAssertTrue(try roundTrip("GET /v1/health HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 200"))
    }

    func testRefusesToDeleteARegularFileAtSocketPath() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sockPath, contents: Data("important".utf8))
        let (server, _) = makeServer()
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(FileManager.default.contents(atPath: sockPath), Data("important".utf8))
    }
}
