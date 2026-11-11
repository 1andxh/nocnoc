import Foundation
import Darwin

/// HTTP server on a unix domain socket.
///
/// Why a unix socket and not localhost:PORT: a socket is a file, so the OS
/// applies file permissions to it. We create it 0600 inside a 0700 directory,
/// so other user accounts can't connect; and nothing on the network (or a web
/// page doing DNS rebinding) can reach it at all.
public final class UnixSocketServer {
    public typealias Handler = (HTTPRequest, ConnectionContext) -> HTTPResponse

    public enum ServerError: Error, Equatable, CustomStringConvertible {
        case alreadyRunning(String)
        case pathNotOurs(String)
        case pathTooLong(String)
        case posix(String, Int32)

        public var description: String {
            switch self {
            case .alreadyRunning(let p): return "another nocnoc is already listening on \(p)"
            case .pathNotOurs(let p): return "\(p) exists and is not a socket owned by you; refusing to remove it"
            case .pathTooLong(let p): return "socket path too long: \(p)"
            case .posix(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    public let path: String
    private let handler: Handler
    private let maxBodyBytes: Int
    private let readTimeoutSeconds: Int
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "nocnoc.accept")

    public init(path: String, maxBodyBytes: Int = 1 << 20, readTimeoutSeconds: Int = 10, handler: @escaping Handler) {
        self.path = path
        self.maxBodyBytes = maxBodyBytes
        self.readTimeoutSeconds = readTimeoutSeconds
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        try removeStaleSocket()

        var addr = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ServerError.pathTooLong(path)
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathBytes)
            buf[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.posix("socket", errno) }

        // umask so the socket file is born 0600 — no window where it's wider.
        let oldMask = umask(0o077)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindErr = errno
        umask(oldMask)
        guard rc == 0 else { close(fd); throw ServerError.posix("bind", bindErr) }
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw ServerError.posix("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
            unlink(path)
        }
    }

    // MARK: - Stale socket handling

    /// A socket file left behind by a crashed run blocks bind(). Remove it —
    /// but only if it's a socket we own and nobody is listening on it.
    private func removeStaleSocket() throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }  // nothing there
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else {
            throw ServerError.pathNotOurs(path)
        }
        if Self.canConnect(path) { throw ServerError.alreadyRunning(path) }
        unlink(path)
    }

    static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    // MARK: - Connections

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }  // EAGAIN: no more pending connections
            // Blocking reads with a timeout, and no SIGPIPE if the client hangs up.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            // One thread per connection: simple, and Phase 2's long-polls
            // will park here while waiting for the user's answer.
            Thread.detachNewThread { [handler, maxBodyBytes] in
                Self.serve(client, maxBodyBytes: maxBodyBytes, handler: handler)
            }
        }
    }

    private static func serve(_ client: Int32, maxBodyBytes: Int, handler: Handler) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            switch HTTPParser.parse(buffer, maxBodyBytes: maxBodyBytes) {
            case .complete(let request):
                let connection = ConnectionContext(isConnected: { isPeerConnected(client) })
                writeAll(client, handler(request, connection).serialized())
                return
            case .invalid(let status, let reason):
                writeAll(client, HTTPResponse.error(status, reason).serialized())
                return
            case .incomplete:
                let n = read(client, &chunk, chunk.count)
                if n <= 0 { return }  // EOF, timeout, or error: drop silently
                buffer.append(chunk, count: n)
            }
        }
    }

    /// Has the client hung up? A non-blocking peek returns 0 bytes only at
    /// EOF; "nothing to read yet" (EAGAIN) means it's still there, waiting.
    static func isPeerConnected(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if n > 0 { return true }
        if n == 0 { return false }
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n <= 0 { return }
                p += n
                left -= n
            }
        }
    }
}
