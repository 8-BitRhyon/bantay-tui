import Foundation

final class HerdrSocketAdapter: Sendable, PlexerAdapter {
    private let herdrBinPath: String

    var kind: PlexerKind { .herdr }

    init(herdrBinPath: String = "herdr") {
        self.herdrBinPath = herdrBinPath
    }

    private func herdrExecutableURL() -> URL? {
        for path in Self.candidateHerdrPaths(
            env: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
            binName: herdrBinPath)
        {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Every location a herdr binary can live, most specific first:
    /// `HERDR_INSTALL_DIR` (official installer's env override), PATH dirs,
    /// `~/.local/bin` (official installer default), Homebrew on Apple
    /// Silicon, Homebrew on Intel, then `~/.herdr/bin`. Pure for tests.
    nonisolated static func candidateHerdrPaths(
        env: [String: String], home: String, binName: String = "herdr"
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            candidates.append(path)
        }
        if let dir = env["HERDR_INSTALL_DIR"], !dir.isEmpty {
            add(dir + "/" + binName)
        }
        if let pathEnv = env["PATH"] {
            for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
                add(String(dir) + "/" + binName)
            }
        }
        add(home + "/.local/bin/" + binName)
        add("/opt/homebrew/bin/" + binName)
        add("/usr/local/bin/" + binName)
        add(home + "/.herdr/bin/" + binName)
        return candidates
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

    func focusPane(paneId: String) {
        paneFocus(paneId: paneId)
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

    /// `pane list` invocation variants in preference order. herdr < 0.8
    /// required `--format json`; herdr 0.8+ removed the flag and emits JSON
    /// by default (the flag now errors). Try both.
    nonisolated static func paneListCommandVariants() -> [[String]] {
        [
            ["pane", "list", "--format", "json"],
            ["pane", "list"],
        ]
    }

    func listPanes() -> [PaneInfo] {
        for args in Self.paneListCommandVariants() {
            let output = runHerdr(args)
            guard !output.isEmpty else { continue }
            let decoder = JSONDecoder()
            guard let jsonData = output.data(using: .utf8),
                let raw = try? decoder.decode(HerdrResponse.self, from: jsonData)
            else {
                continue
            }
            return raw.result?.panes ?? raw.panes ?? []
        }
        return []
    }

    nonisolated func listAgents() async -> [HerdrAgentInfo] {
        if let viaSocket = await listAgentsViaSocket() {
            return viaSocket
        }
        // runHerdr blocks on a child process; hop off the caller's executor
        // so a MainActor caller never stalls the UI thread.
        let output = await Task.detached { [self] in
            self.runHerdr(["agent", "list"])
        }.value
        guard !output.isEmpty else { return [] }

        let decoder = JSONDecoder()
        guard let jsonData = output.data(using: .utf8),
            let raw = try? decoder.decode(HerdrAgentListResponse.self, from: jsonData)
        else {
            return []
        }
        return raw.result?.agents ?? []
    }

    /// Socket-first path: one NDJSON `agent.list` call. Returns nil so the
    /// caller falls back to the CLI when the socket is unavailable.
    nonisolated func listAgentsViaSocket() async -> [HerdrAgentInfo]? {
        let path = HerdrSocketProtocol.socketPath(
            env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let client = HerdrSocketClient(socketURL: URL(fileURLWithPath: path))
        guard let response = await client.call(method: "agent.list"),
            let resultJSON = response.result,
            let data = resultJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let agentsJSON = obj["agents"]
        else {
            return nil
        }
        let agentsData = (try? JSONSerialization.data(withJSONObject: agentsJSON)) ?? Data()
        let decoder = JSONDecoder()
        return try? decoder.decode([HerdrAgentInfo].self, from: agentsData)
    }

    // MARK: - PlexerAdapter

    func captureTail(paneId: String, lines: Int) -> String {
        runHerdr(
            ["pane", "read", paneId, "--source", "recent", "--lines", "\(lines)"],
            timeout: 2.0)
    }

    func sendLine(paneId: String, text: String) {
        _ = runHerdr(["pane", "run", paneId, text], timeout: 1.0)
    }

    func stop(paneId: String) {
        sendKeys(paneId: paneId, keys: ["ctrl+c"])
    }

    func attachPane(paneId: String) {
        paneFocus(paneId: paneId)
    }
}

struct HerdrAgentInfo: Decodable, Sendable {
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
