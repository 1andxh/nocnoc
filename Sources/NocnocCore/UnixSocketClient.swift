import Foundation
import Darwin

/// Lets another thread abort a request in flight (MCP `notifications/cancelled`).
/// Cancelling shuts the socket down; the app sees the hang-up and withdraws
/// the question, exactly as when a hook process dies.
public final class CancelToken {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    fileprivate func attach(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        self.fd = fd
        return true
    }

    fileprivate func detach() {
        lock.lock(); fd = -1; lock.unlock()
    }
}

/// One HTTP request over a unix socket — the Swift twin of the hook's
/// `curl --unix-socket`.
public enum UnixSocketClient {
    public enum ClientError: Error, Equatable {
        case notRunning        // no socket / nobody listening
        case cancelled
        case timedOut
        case badResponse
    }

    public static func request(socketPath: String, method: String, path: String,
                               headers: [String: String] = [:], body: Data = Data(),
                               timeout: TimeInterval, cancel: CancelToken? = nil) throws -> (status: Int, body: Data) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.notRunning }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout.rounded(.up)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw ClientError.notRunning }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw ClientError.notRunning }

        if let cancel, !cancel.attach(fd) { throw ClientError.cancelled }
        defer { cancel?.detach() }

        var head = "\(method) \(path) HTTP/1.1\r\nHost: nocnoc\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        let out = Data((head + "\r\n").utf8) + body
        let wrote = out.withUnsafeBytes { raw -> Bool in
            var p = raw.baseAddress!
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n <= 0 { return false }
                p += n; left -= n
            }
            return true
        }
        guard wrote else { throw cancel?.isCancelled == true ? ClientError.cancelled : ClientError.badResponse }

        // The server closes the connection after replying, so read to EOF.
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { response.append(buf, count: n); continue }
            if n == 0 { break }
            if cancel?.isCancelled == true { throw ClientError.cancelled }
            throw (errno == EAGAIN || errno == EWOULDBLOCK) ? ClientError.timedOut : ClientError.badResponse
        }
        if cancel?.isCancelled == true { throw ClientError.cancelled }

        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              let statusLine = String(data: response[..<split.lowerBound], encoding: .utf8)?
                .components(separatedBy: "\r\n").first,
              let code = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            throw ClientError.badResponse
        }
        return (code, Data(response[split.upperBound...]))
    }
}
