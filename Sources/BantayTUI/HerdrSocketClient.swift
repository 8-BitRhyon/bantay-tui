import Foundation
import Network

/// Pure herdr socket-protocol helpers (NDJSON request/response), kept
/// testable without a live server.
enum HerdrSocketProtocol {
    /// Build a request line: `{"id":...,"method":...,"params":...}`.
    static func requestLine(
        id: String, method: String, paramsJSON: String = "{}"
    ) -> String {
        "{\"id\":\"\(id)\",\"method\":\"\(method)\",\"params\":\(paramsJSON)}"
    }

    struct Response: Equatable, Sendable {
        let id: String
        let result: String?
        let errorCode: String?
        let errorMessage: String?

        var isError: Bool { errorCode != nil }
    }

    /// Parse one response line into id/result/error. Returns nil for
    /// non-JSON or lines missing an id.
    static func parseResponseLine(_ line: String) -> Response? {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = obj["id"] as? String
        else {
            return nil
        }
        if let error = obj["error"] as? [String: Any] {
            return Response(
                id: id,
                result: nil,
                errorCode: error["code"] as? String,
                errorMessage: error["message"] as? String)
        }
        guard let result = obj["result"] else { return nil }
        let resultData = try? JSONSerialization.data(withJSONObject: result)
        return Response(
            id: id,
            result: resultData.flatMap { String(data: $0, encoding: .utf8) },
            errorCode: nil,
            errorMessage: nil)
    }

    /// Split an accumulated byte stream into complete NDJSON lines.
    static func extractLines(from data: Data) -> [String] {
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Resolve the herdr socket path: `HERDR_SOCKET_PATH` wins, else
    /// `~/.config/herdr/herdr.sock`.
    static func socketPath(env: [String: String], home: String) -> String {
        if let explicit = env["HERDR_SOCKET_PATH"], !explicit.isEmpty {
            return explicit
        }
        return home + "/.config/herdr/herdr.sock"
    }
}

/// Direct herdr socket client: sends one NDJSON request per connection,
/// returns the first complete response line. Used by the adapter before
/// falling back to CLI subprocesses.
final class HerdrSocketClient {
    private let socketURL: URL

    init(socketURL: URL) {
        self.socketURL = socketURL
    }

    /// Perform a request and return the parsed response, or nil on any
    /// transport/protocol failure.
    func call(method: String, paramsJSON: String = "{}", timeout: TimeInterval = 1.0)
        async -> HerdrSocketProtocol.Response?
    {
        let id = "req_\(UUID().uuidString.prefix(8))"
        let line = HerdrSocketProtocol.requestLine(id: id, method: method, paramsJSON: paramsJSON)
        let endpoint = NWEndpoint.unix(path: socketURL.path)
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: .main)

        let response = await withCheckedContinuation { continuation in
            var buffer = Data()
            var settled = false
            let settle: (HerdrSocketProtocol.Response?) -> Void = { value in
                guard !settled else { return }
                settled = true
                continuation.resume(returning: value)
            }
            connection.send(
                content: Data((line + "\n").utf8),
                completion: .contentProcessed { error in
                    if error != nil {
                        settle(nil)
                    }
                })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let data {
                    buffer.append(data)
                    let lines = HerdrSocketProtocol.extractLines(from: buffer)
                    if let first = lines.first,
                        let parsed = HerdrSocketProtocol.parseResponseLine(first)
                    {
                        settle(parsed)
                        return
                    }
                }
                if error != nil || isComplete {
                    settle(nil)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                settle(nil)
            }
        }
        connection.cancel()
        return response
    }
}
