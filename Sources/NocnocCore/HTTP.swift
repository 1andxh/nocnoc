import Foundation

/// Minimal HTTP/1.1 over a byte stream — just enough for the hook script's
/// `curl --unix-socket` calls. One request per connection, no keep-alive,
/// no chunked bodies (curl sends Content-Length for `--data-binary @-`).

public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]   // keys lowercased
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data = Data(), contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    /// 200 with an empty body. For hook endpoints this means "no decision":
    /// the hook prints nothing and the agent carries on normally.
    public static let noDecision = HTTPResponse(status: 200)

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    public static func error(_ status: Int, _ reason: String) -> HTTPResponse {
        json(["error": reason], status: status)
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        default: return "Status"
        }
    }
}

public enum HTTPParseResult: Equatable {
    case incomplete
    case complete(HTTPRequest)
    case invalid(status: Int, reason: String)
}

public enum HTTPParser {
    public static let maxHeaderBytes = 16 * 1024

    /// Parse whatever has arrived so far. Returns `.incomplete` until the full
    /// header block and `Content-Length` bytes of body are present.
    public static func parse(_ data: Data, maxBodyBytes: Int) -> HTTPParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes
                ? .invalid(status: 431, reason: "headers too large")
                : .incomplete
        }
        let headerBytes = data[data.startIndex..<headerEnd.lowerBound]
        guard headerBytes.count <= maxHeaderBytes else {
            return .invalid(status: 431, reason: "headers too large")
        }
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            return .invalid(status: 400, reason: "headers are not UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(status: 400, reason: "bad request line")
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, reason: "bad header line")
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if headers["transfer-encoding"] != nil {
            return .invalid(status: 411, reason: "chunked bodies not supported; send Content-Length")
        }

        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else {
                return .invalid(status: 400, reason: "bad Content-Length")
            }
            length = n
        }
        guard length <= maxBodyBytes else {
            return .invalid(status: 413, reason: "body larger than \(maxBodyBytes) bytes")
        }

        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + length)])

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: body))
    }
}
