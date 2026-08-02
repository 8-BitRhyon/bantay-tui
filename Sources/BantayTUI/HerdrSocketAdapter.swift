import Foundation

final class HerdrSocketAdapter: Sendable {
    private let herdrBinPath: String

    init(herdrBinPath: String = "herdr") {
        self.herdrBinPath = herdrBinPath
    }

    private func herdrExecutableURL() -> URL? {
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(
                    herdrBinPath)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        let fallback = URL(fileURLWithPath: "/opt/homebrew/bin").appendingPathComponent(
            herdrBinPath)
        return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback : nil
    }

    private func runHerdr(_ arguments: [String], timeout: TimeInterval = 3.0) -> String {
        guard let url = herdrExecutableURL() else { return "" }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                process.terminate()
            }
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func paneFocus(paneId: String) {
        _ = runHerdr(["agent", "focus", paneId], timeout: 1.0)
    }

    func agentPrompt(paneId: String, text: String) {
        _ = runHerdr(["agent", "prompt", paneId, text], timeout: 1.0)
    }

    /// Sends raw key presses to an agent's terminal. Works without focus.
    func sendKeys(paneId: String, keys: [String]) {
        var arguments = ["agent", "send-keys", paneId]
        arguments.append(contentsOf: keys)
        _ = runHerdr(arguments, timeout: 1.0)
    }

    /// Approves a yes-no "Need approval" prompt (e.g. "y" + Enter).
    func approve(paneId: String) {
        sendKeys(paneId: paneId, keys: ["y", "enter"])
    }

    /// Denies a yes-no "Need approval" prompt (e.g. "n" + Enter).
    func deny(paneId: String) {
        sendKeys(paneId: paneId, keys: ["n", "enter"])
    }

    /// Responds to a single-choice (choices) prompt by sending the 1-based
    /// option index followed by Enter.
    func approveChoice(paneId: String, choice: Int) {
        sendKeys(paneId: paneId, keys: [String(choice), "enter"])
    }

    /// Responds to a multi-select prompt by sending the comma-joined,
    /// 1-based option indices followed by Enter (e.g. "1,3" + Enter).
    func approveMulti(paneId: String, selections: [Int]) {
        let joined = selections.map(String.init).joined(separator: ",")
        sendKeys(paneId: paneId, keys: [joined, "enter"])
    }

    func spawnAgentWait(paneId: String, statuses: [String]) -> Process? {
        guard let url = herdrExecutableURL() else { return nil }
        var arguments = ["agent", "wait", paneId]
        for status in statuses {
            arguments += ["--until", status]
        }
        arguments += ["--timeout", "1800000"]
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    func listPanes() -> [PaneInfo] {
        let output = runHerdr(["pane", "list", "--format", "json"])
        guard !output.isEmpty else { return [] }

        let decoder = JSONDecoder()
        guard let jsonData = output.data(using: .utf8),
            let raw = try? decoder.decode(HerdrResponse.self, from: jsonData)
        else {
            return []
        }
        return raw.result?.panes ?? raw.panes ?? []
    }

    nonisolated func listAgents() async -> [HerdrAgentInfo] {
        let output = runHerdr(["agent", "list"])
        guard !output.isEmpty else { return [] }

        let decoder = JSONDecoder()
        guard let jsonData = output.data(using: .utf8),
            let raw = try? decoder.decode(HerdrAgentListResponse.self, from: jsonData)
        else {
            return []
        }
        return raw.result?.agents ?? []
    }
}

struct HerdrAgentInfo: Decodable {
    let agent: String
    let agentStatus: String?
    let paneId: String?
    let workspaceId: String?
    let terminalTitle: String?

    enum CodingKeys: String, CodingKey {
        case agent
        case agentStatus = "agent_status"
        case paneId = "pane_id"
        case workspaceId = "workspace_id"
        case terminalTitle = "terminal_title_stripped"
    }
}

private struct HerdrAgentListResponse: Decodable {
    let result: HerdrAgentListResult?
}

private struct HerdrAgentListResult: Decodable {
    let agents: [HerdrAgentInfo]?
}

private struct HerdrResponse: Decodable {
    let result: HerdrPaneListResult?
    let panes: [PaneInfo]?
}

private struct HerdrPaneListResult: Decodable {
    let panes: [PaneInfo]?
}

struct PaneInfo: Decodable {
    let id: String
    let title: String?
    let cwd: String?
    let workspaceId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case cwd
        case workspaceId = "workspace_id"
    }
}
