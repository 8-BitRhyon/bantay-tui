import Foundation

/// Minimal, zero-dependency Model Context Protocol (MCP) server for Bantay-TUI.
/// Speaks JSON-RPC 2.0 over standard I/O (stdio), allowing any MCP client
/// (Cursor, Windsurf, Zed, Goose, Claude Desktop, OpenHands) to emit status,
/// request approvals, and stream logs directly to Bantay's Dynamic Island.
enum BantayMCPServer {
    static let protocolVersion = "2024-11-05"
    static let serverName = "bantay"
    static let serverVersion = "0.1.0"

    /// Dispatches a single incoming JSON-RPC 2.0 message string.
    /// Returns the JSON-RPC response string, or nil for notifications.
    static func processMessage(_ input: String, eventsPath: String? = nil) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return makeErrorResponse(
                id: nil, code: -32700, message: "Parse error: invalid JSON")
        }

        let id = json["id"]
        guard let method = json["method"] as? String else {
            return makeErrorResponse(
                id: id, code: -32600, message: "Invalid Request: missing method")
        }

        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return makeInitializeResponse(id: id)

        case "notifications/initialized":
            return nil

        case "ping":
            return makeSuccessResponse(id: id, result: [:])

        case "tools/list":
            return makeToolsListResponse(id: id)

        case "tools/call":
            return handleToolCall(id: id, params: params, eventsPath: eventsPath)

        default:
            return makeErrorResponse(
                id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func makeInitializeResponse(id: Any?) -> String {
        let result: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [
                "tools": [:] as [String: Any]
            ],
            "serverInfo": [
                "name": serverName,
                "version": serverVersion,
            ],
        ]
        return makeSuccessResponse(id: id, result: result)
    }

    private static func makeToolsListResponse(id: Any?) -> String {
        let tools: [[String: Any]] = [
            [
                "name": "bantay_set_status",
                "description": "Update agent state, message, and metrics in Bantay Dynamic Island.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent": [
                            "type": "string",
                            "description": "Agent name (e.g. claude, windsurf, goose, aider)",
                        ],
                        "status": [
                            "type": "string",
                            "enum": [
                                "idle", "thinking", "executing", "blocked",
                                "needs_approval", "complete", "error",
                            ],
                            "description": "Current lifecycle status",
                        ],
                        "message": [
                            "type": "string",
                            "description": "Short activity summary",
                        ],
                        "cost": [
                            "type": "number",
                            "description": "Session cost in USD",
                        ],
                        "tokens": [
                            "type": "number",
                            "description": "Total tokens consumed",
                        ],
                    ],
                    "required": ["status"],
                ] as [String: Any],
            ],
            [
                "name": "bantay_request_approval",
                "description": "Request explicit user approval with options in Bantay Island.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent": [
                            "type": "string",
                            "description": "Agent name",
                        ],
                        "title": [
                            "type": "string",
                            "description": "Prompt title for the approval",
                        ],
                        "details": [
                            "type": "string",
                            "description": "Action details, command, or diff to approve",
                        ],
                        "options": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Choices, e.g. ['Yes', 'No', 'Always']",
                        ],
                    ],
                    "required": ["title"],
                ] as [String: Any],
            ],
            [
                "name": "bantay_log",
                "description":
                    "Log an activity event into Bantay's event timeline and Peek overlay.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent": [
                            "type": "string",
                            "description": "Agent name",
                        ],
                        "message": [
                            "type": "string",
                            "description": "Log or progress message",
                        ],
                        "level": [
                            "type": "string",
                            "enum": ["info", "warn", "error"],
                            "description": "Severity level",
                        ],
                    ],
                    "required": ["message"],
                ] as [String: Any],
            ],
        ]
        return makeSuccessResponse(id: id, result: ["tools": tools])
    }

    private static func handleToolCall(
        id: Any?, params: [String: Any], eventsPath: String?
    ) -> String {
        guard let name = params["name"] as? String else {
            return makeErrorResponse(
                id: id, code: -32602, message: "Invalid params: missing tool name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "bantay_set_status":
            guard let status = arguments["status"] as? String else {
                return makeErrorResponse(
                    id: id, code: -32602, message: "Invalid params: missing 'status'")
            }
            let agent = arguments["agent"] as? String ?? "agent"
            let message = arguments["message"] as? String
            let mappedKind: String
            switch status.lowercased() {
            case "idle": mappedKind = "idle"
            case "thinking", "executing": mappedKind = "progress"
            case "blocked": mappedKind = "waiting"
            case "needs_approval": mappedKind = "access_request"
            case "complete": mappedKind = "completed"
            case "error": mappedKind = "failed"
            default: mappedKind = "progress"
            }
            let payload: [String: Any] = [
                "source": agent,
                "type": mappedKind,
                "message": message ?? status,
                "paneId": "mcp:\(agent)",
            ]
            appendEvent(payload, to: eventsPath)
            return makeToolCallSuccess(id: id, text: "Status updated to \(status)")

        case "bantay_request_approval":
            guard let title = arguments["title"] as? String else {
                return makeErrorResponse(
                    id: id, code: -32602, message: "Invalid params: missing 'title'")
            }
            let agent = arguments["agent"] as? String ?? "agent"
            let details = arguments["details"] as? String
            let options = arguments["options"] as? [String]
            var payload: [String: Any] = [
                "source": agent,
                "type": "access_request",
                "title": title,
                "message": details ?? title,
                "paneId": "mcp:\(agent)",
            ]
            if let options, !options.isEmpty {
                payload["variance"] = "choices"
                payload["choices"] = options
            } else {
                payload["variance"] = "yes-no"
            }
            appendEvent(payload, to: eventsPath)
            return makeToolCallSuccess(id: id, text: "Approval requested for: \(title)")

        case "bantay_log":
            guard let message = arguments["message"] as? String else {
                return makeErrorResponse(
                    id: id, code: -32602, message: "Invalid params: missing 'message'")
            }
            let agent = arguments["agent"] as? String ?? "agent"
            let payload: [String: Any] = [
                "source": agent,
                "type": "progress",
                "message": message,
                "paneId": "mcp:\(agent)",
            ]
            appendEvent(payload, to: eventsPath)
            return makeToolCallSuccess(id: id, text: "Event logged")

        default:
            return makeErrorResponse(
                id: id, code: -32601, message: "Tool not found: \(name)")
        }
    }

    private static func appendEvent(_ payload: [String: Any], to customPath: String?) {
        let path = customPath ?? LaunchAgent.eventsFilePath()
        guard let lineData = try? JSONSerialization.data(withJSONObject: payload),
            var lineString = String(data: lineData, encoding: .utf8)
        else {
            return
        }
        lineString.append("\n")

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data(lineString.utf8))
    }

    private static func makeToolCallSuccess(id: Any?, text: String) -> String {
        let result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ]
            ],
            "isError": false,
        ]
        return makeSuccessResponse(id: id, result: result)
    }

    private static func makeSuccessResponse(id: Any?, result: [String: Any]) -> String {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id {
            envelope["id"] = id
        } else {
            envelope["id"] = NSNull()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
            let jsonStr = String(data: data, encoding: .utf8)
        else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{}}"
        }
        return jsonStr
    }

    private static func makeErrorResponse(id: Any?, code: Int, message: String) -> String {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        if let id {
            envelope["id"] = id
        } else {
            envelope["id"] = NSNull()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
            let jsonStr = String(data: data, encoding: .utf8)
        else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":\(code),"
                + "\"message\":\"\(message)\"}}"
        }
        return jsonStr
    }

    /// Run stdio event loop for command-line MCP invocation.
    static func runStdioLoop() {
        let standardInput = FileHandle.standardInput
        let standardOutput = FileHandle.standardOutput

        while true {
            let data = standardInput.availableData
            guard !data.isEmpty else { break }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline)
            for line in lines {
                let str = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !str.isEmpty else { continue }
                if let response = processMessage(str) {
                    let outData = Data((response + "\n").utf8)
                    standardOutput.write(outData)
                }
            }
        }
    }
}
