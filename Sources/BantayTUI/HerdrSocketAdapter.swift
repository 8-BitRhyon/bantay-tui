import Foundation

final class HerdrSocketAdapter {
    private let herdrBinPath: String
    private var task: Process?

    init(herdrBinPath: String = "herdr") {
        self.herdrBinPath = herdrBinPath
    }

    func paneAgentStatus(paneId: String, timeoutMs: Int = 30000) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/" + herdrBinPath)
            process.arguments = ["wait", "agent-status", paneId, "--status", "done", "--timeout", String(timeoutMs)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func paneFocus(paneId: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/" + herdrBinPath)
        process.arguments = ["pane", "focus", paneId]
        try? process.run()
    }

    func listPanes() async throws -> [PaneInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/" + herdrBinPath)
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
              let raw = try? decoder.decode(HerdrResponse.self, from: jsonData) else {
            return []
        }
        return raw.result?.panes ?? raw.panes ?? []
    }
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
