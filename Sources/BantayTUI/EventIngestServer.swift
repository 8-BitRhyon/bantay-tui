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
    private var unixListener: UnixIngestListener?

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

    /// Bind the local Unix-domain ingest listener (plan 017 W2). Independent
    /// of the TCP listener; gated by `ingestSocketEnabled` (default ON — a
    /// user-owned socket file is not a network exposure).
    func startUnixSocket() {
        unixListener?.stop()
        unixListener = nil
        let listener = UnixIngestListener(
            path: Self.ingestSocketPath(), token: token, onLine: onLine)
        listener.start()
        unixListener = listener
    }

    func stopUnixSocket() {
        unixListener?.stop()
        unixListener = nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stopUnixSocket()
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
            respond(to: request, token: token, onLine: onLine, connection: connection)
        }
    }

    /// Shared HTTP handling for the TCP and UDS ingest listeners: the
    /// constant-time token gate first, then forward the body line and ack —
    /// or 400 on a non-UTF8 body. Identical behavior on both transports.
    private static func respond(
        to request: IngestHTTP.Request,
        token: String,
        onLine: @escaping @Sendable (String) -> Void,
        connection: NWConnection
    ) {
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

// MARK: - UDS ingest pure helpers (W2)

extension EventIngestServer {
    /// Max bytes accepted on one ingest connection (matches the TCP
    /// listener's 64 KiB receive cap).
    static let maxIngestLineBytes = 64 * 1024

    /// Bare-line form prefix: the connection starts with `token <secret>`.
    static let bareLineTokenPrefix = "token "

    /// Resolve the UDS socket path: `BANTAY_INGEST_SOCKET` wins, else
    /// `~/Library/Application Support/Bantay-TUI/ingest.sock`.
    static func ingestSocketPath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let override = env["BANTAY_INGEST_SOCKET"], !override.isEmpty {
            return override
        }
        return (home as NSString).appendingPathComponent(
            "Library/Application Support/Bantay-TUI/ingest.sock")
    }

    /// True when the buffered bytes are not a complete HTTP POST — the
    /// connection must be using the bare NDJSON form (no `\r\n\r\n` / valid
    /// Content-Length).
    static func isBareLineRequest(_ buffer: Data) -> Bool {
        IngestHTTP.request(from: buffer) == nil
    }

    /// True when `line` decodes as an `AgentEventPayload` — the same
    /// decoder path `ingestEventLine` uses for events-file lines.
    static func validateBareLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONDecoder().decode(AgentEventPayload.self, from: data)) != nil
    }

    /// Extract the secret from a `token <secret>` prefix line.
    static func bareLineToken(from firstLine: String) -> String? {
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(bareLineTokenPrefix) else { return nil }
        let presented = String(trimmed.dropFirst(bareLineTokenPrefix.count))
            .trimmingCharacters(in: .whitespaces)
        return presented.isEmpty ? nil : presented
    }

    /// Parse the full bare NDJSON form — a `token <secret>` line then ONE
    /// event JSON line. Returns the validated event line, or nil on any
    /// mismatch (missing line, wrong token, non-payload JSON).
    static func bareLineEvent(buffer: Data, expectedToken: String) -> String? {
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.count == 2 else { return nil }
        guard let presented = bareLineToken(from: lines[0]) else { return nil }
        guard NotchHUDConfig.tokenMatches(presented, expected: expectedToken) else { return nil }
        let eventLine = lines[1]
        guard validateBareLine(eventLine) else { return nil }
        return eventLine
    }

    /// True when the connection's bytes exceed the single-line cap and must
    /// be rejected before they exhaust the receive buffer.
    static func isOversized(_ data: Data) -> Bool {
        data.count > maxIngestLineBytes
    }

    /// Stale-socket decision: a bind failure with a leftover socket file can
    /// only mean a crashed run (this app is the socket's single owner), so
    /// unlink and rebind. Never unlink when no file exists or the bind
    /// succeeded.
    static func shouldUnlinkStaleSocket(bindFailed: Bool, socketExists: Bool) -> Bool {
        bindFailed && socketExists
    }
}

/// Accepts event lines over a Unix-domain socket (plan 017 W2).
///
/// Implemented on POSIX `socket(AF_UNIX)` rather than `NWListener`: this
/// SDK's Network.framework exposes no UNIX listener API (`NWParameters.unix`
/// is unavailable and forcing a unix `requiredLocalEndpoint` fails with
/// EINVAL), so the listen socket and per-connection reads are owned here.
/// The socket file is created mode 0600 inside the (0700) app-support
/// directory, so only the owning user can reach it.
///
/// One connection carries either:
///   1. an HTTP POST — same `IngestHTTP` parsing as the TCP listener
///      (`curl --unix-socket <path> -X POST --data-binary @-
///      "http://localhost/events?token=<secret>"`), or
///   2. the bare NDJSON form — a `token <secret>` line, ONE event JSON
///      line, then close (the "any CLI tool/script" path).
/// Both forms validate through the same `AgentEventPayload` decoder and
/// funnel into the same `ingestEventLine`.
final class UnixIngestListener {
    private let path: String
    private let token: String
    private let onLine: @Sendable (String) -> Void
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connectionStates: [Int32: ConnectionState] = [:]
    private var active = false

    init(path: String, token: String, onLine: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.token = token
        self.onLine = onLine
    }

    /// Bind, listen, and start accepting. Removes a stale socket file first
    /// (this app is the socket's only owner); on a failed bind with a
    /// leftover file, unlinks and retries once.
    func start() {
        guard !active else { return }
        active = true
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var fd = bindAndListen()
        if fd < 0,
            EventIngestServer.shouldUnlinkStaleSocket(
                bindFailed: true,
                socketExists: FileManager.default.fileExists(atPath: path))
        {
            try? FileManager.default.removeItem(atPath: path)
            fd = bindAndListen()
        }
        guard fd >= 0 else {
            active = false
            return
        }
        listenFD = fd
        // Mode 0600: only the owning user may connect, even if the
        // app-support directory were looser. Chmod after bind — the socket
        // file only exists once bound.
        _ = chmod(path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            self?.listenFD = -1
        }
        source.resume()
        listenSource = source
    }

    func stop() {
        active = false
        listenSource?.cancel()
        listenSource = nil
        // Copy before clearing: `values` is a live view, and `close()` below
        // mutates the dictionary via onClose.
        let states = Array(connectionStates.values)
        connectionStates.removeAll()
        for state in states {
            state.close()
        }
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        // Clean shutdown removes the socket file so no stale file survives a
        // later relaunch.
        try? FileManager.default.removeItem(atPath: path)
    }

    private func bindAndListen() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = UnixIngestListener.makeAddress(path)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return -1
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    private static func makeAddress(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        // Write sun_path through a pointer to the whole struct to keep the
        // exclusive access to `addr` in one place. On Darwin `sun_path`
        // starts after `sun_len` + `sun_family`, so use the stored-property
        // offset rather than assuming a 1-byte family.
        withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<sockaddr_un>.size) {
                raw in
                let offset =
                    MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)
                    ?? MemoryLayout<sa_family_t>.size
                let capacity = MemoryLayout<sockaddr_un>.size - offset
                let count = min(pathBytes.count, capacity - 1)
                for i in 0..<count {
                    raw[offset + i] = CChar(bitPattern: pathBytes[i])
                }
            }
        }
        return addr
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { break }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let state = ConnectionState(
                fd: fd, token: token, onLine: onLine,
                onClose: { [weak self] closedFD in
                    self?.connectionStates[closedFD] = nil
                })
            connectionStates[fd] = state
            state.start()
        }
    }
}

/// Per-accepted-connection read state. Reads on the main queue via a
/// DispatchSource; settles exactly once when the payload form is complete
/// (HTTP Content-Length, or the bare form's token + event lines once both are
/// present or EOF arrives). A 5s deadline closes idle connections so a writer
/// that never closes cannot pin a connection forever.
private final class ConnectionState {
    private let fd: Int32
    private let token: String
    private let onLine: @Sendable (String) -> Void
    private let onClose: (Int32) -> Void
    private var source: DispatchSourceRead?
    private var deadline: DispatchWorkItem?
    private var buffer = Data()
    private var settled = false
    private var tornDown = false

    init(
        fd: Int32, token: String, onLine: @escaping @Sendable (String) -> Void,
        onClose: @escaping (Int32) -> Void
    ) {
        self.fd = fd
        self.token = token
        self.onLine = onLine
        self.onClose = onClose
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [weak self] in
            self?.teardown()
        }
        source.resume()
        self.source = source
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(with: IngestHTTP.forbiddenResponse())
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
    }

    private func readAvailable() {
        guard !settled else { return }
        var chunk = [UInt8](repeating: 0, count: EventIngestServer.maxIngestLineBytes)
        while !settled {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if EventIngestServer.isOversized(buffer) {
                    finish(with: IngestHTTP.badResponse())
                    return
                }
                // Form 1 (HTTP POST) settles mid-stream via Content-Length.
                if IngestHTTP.request(from: buffer) != nil {
                    handleHTTP()
                    return
                }
                // Form 2 (bare NDJSON) settles as soon as both lines arrive.
                if let line = EventIngestServer.bareLineEvent(
                    buffer: buffer, expectedToken: token)
                {
                    handleBareLine(line)
                    return
                }
            } else if n == 0 {
                break
            } else {
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    return
                default:
                    finish(with: IngestHTTP.badResponse())
                    return
                }
            }
        }
        guard !settled else { return }
        // EOF — settle whatever remains: HTTP that arrived in split reads, or
        // the bare form (which has no framing, so it needs the writer to
        // close).
        if IngestHTTP.request(from: buffer) != nil {
            handleHTTP()
        } else if let line = EventIngestServer.bareLineEvent(buffer: buffer, expectedToken: token) {
            handleBareLine(line)
        } else {
            finish(with: IngestHTTP.forbiddenResponse())
        }
    }

    private func handleHTTP() {
        guard !settled, let request = IngestHTTP.request(from: buffer) else {
            finish(with: IngestHTTP.forbiddenResponse())
            return
        }
        // Auth gate: constant-time token comparison, same as the TCP path.
        guard let presented = request.token,
            NotchHUDConfig.tokenMatches(presented, expected: token)
        else {
            finish(with: IngestHTTP.forbiddenResponse())
            return
        }
        guard let line = String(data: request.body, encoding: .utf8) else {
            finish(with: IngestHTTP.badResponse())
            return
        }
        onLine(line)
        finish(with: IngestHTTP.okResponse())
    }

    private func handleBareLine(_ line: String) {
        onLine(line)
        finish(with: IngestHTTP.okResponse())
    }

    /// Respond (best-effort) and tear the connection down exactly once.
    private func finish(with response: Data) {
        guard !settled else { return }
        settled = true
        deadline?.cancel()
        deadline = nil
        _ = response.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
        teardown()
    }

    /// Tear the connection down without writing a response (server shutdown).
    func close() {
        guard !settled else { return }
        settled = true
        deadline?.cancel()
        deadline = nil
        teardown()
    }

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        source?.cancel()
        source = nil
        Darwin.close(fd)
        onClose(fd)
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
