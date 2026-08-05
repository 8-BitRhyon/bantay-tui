import Foundation
import Network

/// Minimal HTTP request parsing for the local event-ingest listener.
/// Remote agents (or SSH tunnels) POST one JSON event line per request.
enum IngestHTTP {
    struct Request: Equatable, Sendable {
        let method: String
        let token: String?
        let body: Data
    }

    /// Extract method, optional `?token=` query param, and body from raw HTTP
    /// bytes. Requires a `\r\n\r\n` header terminator and a valid
    /// Content-Length; returns nil when the body is not yet complete or the
    /// request is not POST.
    static func request(from data: Data) -> Request? {
        guard let terminator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<terminator.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.split(separator: "\r\n").map(String.init)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ").map(String.init)
        guard parts.count >= 2, parts[0].uppercased() == "POST" else { return nil }
        // The request target may carry `?token=<secret>` on /events.
        let target = parts[1]
        let token: String?
        if let queryStart = target.firstIndex(of: "?") {
            let query = target[target.index(after: queryStart)...]
            token = query.split(separator: "&").first { $0.hasPrefix("token=") }
                .map { String($0.dropFirst("token=".count)) }
        } else {
            token = nil
        }
        let contentLength =
            lines.compactMap { line -> Int? in
                let kv = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard kv.count == 2, kv[0].lowercased() == "content-length" else { return nil }
                return Int(kv[1])
            }.first
        let bodyStart = terminator.upperBound
        guard let contentLength, contentLength >= 0,
            data.count >= bodyStart + contentLength
        else {
            return nil
        }
        return Request(
            method: parts[0],
            token: token,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength)))
    }

    /// 200 OK with a tiny body.
    static func okResponse() -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
    }

    /// 400 Bad Request.
    static func badResponse() -> Data {
        Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    /// 403 Forbidden — request rejected for a missing/invalid ingest token.
    static func forbiddenResponse() -> Data {
        Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    /// Clamp a port into the valid user-port range.
    static func clampedPort(_ port: Int) -> UInt16 {
        UInt16(min(max(port, 1024), 65535))
    }
}

/// Localhost event-ingest listener. Receives POSTed JSON event lines from
/// remote agents (e.g. over `ssh -R <port>:localhost:<port>`), validates them
/// with the agent payload decoder, and forwards them to the app via `onLine`.
/// Every request must present the matching ingest token (`?token=…`) —
/// otherwise 403 and the event is dropped, so a local process cannot forge
/// events or keystroke-inject approvals.
final class EventIngestServer {
    private let port: UInt16
    private let token: String
    private let onLine: @Sendable (String) -> Void
    private var listener: NWListener?

    init(port: UInt16, token: String, onLine: @escaping @Sendable (String) -> Void) {
        self.port = port
        self.token = token
        self.onLine = onLine
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try? NWListener(using: parameters)
        self.listener = listener
        let onLine = self.onLine
        let token = self.token
        listener?.newConnectionHandler = { connection in
            Self.accept(connection, token: token, onLine: onLine)
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func accept(
        _ connection: NWConnection, token: String, onLine: @escaping @Sendable (String) -> Void
    ) {
        connection.start(queue: .main)
        let buffer = ReceiveBuffer()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            if let data {
                buffer.append(data)
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            guard let request = IngestHTTP.request(from: buffer.data) else {
                connection.cancel()
                return
            }
            // Auth gate: constant-time token comparison. Reject early (no
            // body parse, no event forward) on any mismatch or absence.
            guard let presented = request.token,
                NotchHUDConfig.tokenMatches(presented, expected: token)
            else {
                connection.send(
                    content: IngestHTTP.forbiddenResponse(),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                return
            }
            if let line = String(data: request.body, encoding: .utf8) {
                onLine(line)
                connection.send(
                    content: IngestHTTP.okResponse(),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
            } else {
                connection.send(
                    content: IngestHTTP.badResponse(),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
            }
        }
    }
}

/// Mutable receive buffer shared with the `@Sendable` receive handler.
/// A class lets us mutate it without tripping the captured-var warning.
private final class ReceiveBuffer: @unchecked Sendable {
    var data = Data()

    func append(_ newData: Data) {
        data.append(newData)
    }
}
