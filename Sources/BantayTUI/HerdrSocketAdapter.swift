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

    func paneFocus(paneId: String) {
        guard let url = herdrExecutableURL() else { return }
        let process = Process()
        process.executableURL = url
        process.arguments = ["pane", "focus", paneId]
        try? process.run()
    }

    func listPanes() async throws -> [PaneInfo] {
        guard let url = herdrExecutableURL() else { return [] }
        let process = Process()
        process.executableURL = url
        process.arguments = ["pane", "list", "--format", "json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
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
        guard let url = herdrExecutableURL() else { return [] }
        let process = Process()
        process.executableURL = url
        process.arguments = ["agent", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
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
