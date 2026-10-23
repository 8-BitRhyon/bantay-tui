#if canImport(Testing)
    import Foundation
    import SQLite3
    import Testing

    @testable import BantayTUI

    @MainActor
    @Suite("Provider Quota and GUI Agent Detection", .serialized)
    struct QuotaTrackerTests {
        @Test("probeLiveQuotas emits rows only for reported quotas")
        func liveQuotaHonesty() {
            let emptyHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-noquota-\(UUID().uuidString)").path
            let quotas = QuotaAxiTracker.probeLiveQuotas(
                activeProviders: [
                    "codex", "cursor", "cloudcode", "claude",
                    "antigravity", "windsurf", "kilo",
                ],
                costUSD: 2.50,
                budgetUSD: 10.00,
                burnRateTPM: 120.0,
                home: emptyHome
            )
            #expect(quotas.isEmpty)
        }

        @Test("opencode quota state reflects the ledger limit wall")
        func opencodeQuotaState() {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-opencode-quota-\(UUID().uuidString)")
            let share = dir.appendingPathComponent(".local/share/opencode", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: share, withIntermediateDirectories: true)
            let db = share.appendingPathComponent("opencode.db")
            var handle: OpaquePointer?
            guard sqlite3_open(db.path, &handle) == SQLITE_OK, let dbHandle = handle else {
                Issue.record("mock opencode DB failed to open")
                return
            }
            defer { sqlite3_close(dbHandle) }
            sqlite3_exec(
                dbHandle,
                "CREATE TABLE session_message(id TEXT PRIMARY KEY, session_id TEXT NOT NULL,"
                    + " type TEXT NOT NULL, seq INTEGER NOT NULL, time_created INTEGER NOT NULL,"
                    + " time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
                nil, nil, nil)
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let payload =
                "{\"tokens\":{\"input\":100,\"output\":10,\"reasoning\":0,"
                + "\"cache\":{\"read\":0,\"write\":0}},\"cost\":0.01,"
                + "\"content\":[{\"type\":\"text\",\"text\":\"QuotaExceeded: Free usage limit\"}]}"
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(
                dbHandle,
                "INSERT INTO session_message VALUES (?,?,?,?,?,?,?)",
                -1, &stmt, nil)
            if let stmt {
                sqlite3_bind_text(stmt, 1, "m1", -1, transient)
                sqlite3_bind_text(stmt, 2, "s1", -1, transient)
                sqlite3_bind_text(stmt, 3, "assistant", -1, transient)
                sqlite3_bind_int64(stmt, 4, 1)
                sqlite3_bind_int64(stmt, 5, nowMs)
                sqlite3_bind_int64(stmt, 6, nowMs)
                sqlite3_bind_text(stmt, 7, (payload as NSString).utf8String, -1, transient)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            let state = OpenCodeUsageAdapter.quotaState(
                now: Date(), home: dir.path)
            #expect(state?.limitReached == true)
            #expect((state?.costTodayUSD ?? 0) > 0)
            let quotas = QuotaAxiTracker.probeLiveQuotas(
                activeProviders: ["opencode"],
                costUSD: 0.01,
                budgetUSD: 10.0,
                home: dir.path
            )
            let opencode = quotas.first { $0.id == "opencode" }
            #expect(opencode?.limitReached == true)
            #expect(opencode?.remainingPercent == 0)
            try? FileManager.default.removeItem(at: dir)
        }

        @Test("opencode Go rows track per-model plan allowances")
        func opencodeGoAllowances() {
            let tight = OpenCodeGoLimits.tightestWindow(
                spend5h: 2.0, spend7d: 3.0, spend30d: 4.0, monthlyLimit: 60.0)
            #expect(tight.window == .fiveHour)
            #expect(abs(tight.allowance - 12.0) < 0.001)
            #expect(
                abs(
                    OpenCodeGoLimits.remainingPercent(
                        spend: tight.spend, allowance: tight.allowance) - 83.33)
                    < 0.1)
            #expect(
                OpenCodeGoLimits.limit(
                    for: "deepseek-v4.1-flash", plan: .go
                )?.goMonthlyUSD == 80)
            #expect(
                OpenCodeGoLimits.limit(
                    for: "Muse Spark 1.3 Contributor", plan: .goPlus
                )?.goPlusMonthlyUSD == 120)
            #expect(OpenCodeGoLimits.limit(for: "unknown-model", plan: .go) == nil)
        }

        @Test("quotaThresholds detects warning and critical status correctly")
        func quotaThresholds() {
            let normal = ProviderQuota(provider: "Claude Code", remainingPercent: 45.0)
            #expect(!normal.isWarning)
            #expect(!normal.isCritical)

            let warning = ProviderQuota(provider: "OpenAI Codex", remainingPercent: 18.0)
            #expect(warning.isWarning)
            #expect(!warning.isCritical)

            let critical = ProviderQuota(provider: "Cursor", remainingPercent: 4.5)
            #expect(critical.isWarning)
            #expect(critical.isCritical)

            let zero = ProviderQuota(provider: "Cursor", remainingPercent: 0.0)
            #expect(zero.isWarning)
            #expect(zero.isCritical)
        }

        @Test("burnRateAndForecasting evaluates rate thresholds and hours remaining")
        func burnRateAndForecasting() {
            // High burn rate threshold at 2500 TPM
            #expect(QuotaAxiTracker.isHighBurnRate(tokensPerMin: 2500.0))
            #expect(QuotaAxiTracker.isHighBurnRate(tokensPerMin: 4000.0))
            #expect(!QuotaAxiTracker.isHighBurnRate(tokensPerMin: 2499.0))
            #expect(!QuotaAxiTracker.isHighBurnRate(tokensPerMin: 0.0))

            // Forecasting remaining hours
            let forecast = QuotaAxiTracker.forecastHoursRemaining(
                tokensPerMin: 500.0,
                remainingPercent: 50.0
            )
            #expect(forecast != nil)
            if let hours = forecast {
                #expect(hours > 0.0 && hours <= 99.0)
            }

            // Inactive burn rate (<= 50 TPM) yields nil forecast
            #expect(
                QuotaAxiTracker.forecastHoursRemaining(
                    tokensPerMin: 20.0,
                    remainingPercent: 50.0
                ) == nil
            )
            // Empty remaining quota yields nil forecast
            #expect(
                QuotaAxiTracker.forecastHoursRemaining(
                    tokensPerMin: 500.0,
                    remainingPercent: 0.0
                ) == nil
            )
        }

        @Test("overBudgetSpend clamps reported percentages without crash")
        func overBudgetSpend() {
            let quotas = QuotaAxiTracker.probeLiveQuotas(
                activeProviders: ["claude", "antigravity"],
                costUSD: 25.00,
                budgetUSD: 10.00,
                burnRateTPM: 100.0,
                home: FileManager.default.temporaryDirectory
                    .appendingPathComponent("bantay-noquota-\(UUID().uuidString)").path
            )
            #expect(quotas.isEmpty)
            for q in quotas {
                #expect(q.remainingPercent >= 0.0)
                #expect(q.remainingPercent <= 100.0)
            }
        }

        @Test("parseQuotaJSON handles extended fields, fallbacks, and malformed inputs")
        func parseExtendedQuotaJSON() {
            let json = """
                [
                    {
                        "provider": "Cursor",
                        "remainingPercent": 68.0,
                        "reset": "Renews Oct 1",
                        "tier": "Pro",
                        "used": "160 / 500 reqs",
                        "total": "500 Fast"
                    }
                ]
                """
            let parsed = QuotaAxiTracker.parseQuotaJSON(json)
            #expect(parsed.count == 1)
            let item = parsed[0]
            #expect(item.id == "cursor")
            #expect(item.provider == "Cursor")
            #expect(item.remainingPercent == 68.0)
            #expect(item.resetHint == "Renews Oct 1")
            #expect(item.tier == "Pro")
            #expect(item.usedDisplay == "160 / 500 reqs")
            #expect(item.totalDisplay == "500 Fast")
            #expect(!item.isWarning)
            #expect(!item.isCritical)

            // Malformed JSON falls back gracefully to empty list without crash
            let fallbackMalformed = QuotaAxiTracker.parseQuotaJSON("{ not valid json }")
            #expect(fallbackMalformed.isEmpty)

            // Empty string falls back gracefully to empty list
            let fallbackEmpty = QuotaAxiTracker.parseQuotaJSON("")
            #expect(fallbackEmpty.isEmpty)
        }

        @Test("AgentDetector covers Cursor, Codex, and Cloud Code paths")
        func agentDetectorSearchPaths() {
            let home = "/tmp/test-home"
            let cursorPaths = AgentDetector.transcriptSearchPaths(home: home, name: "cursor")
            #expect(cursorPaths.contains(home + "/.cursor-agent"))
            #expect(cursorPaths.contains(home + "/.cursor"))
            let cursorStorage = home + "/Library/Application Support/Cursor/User/workspaceStorage"
            #expect(cursorPaths.contains(cursorStorage))

            let codexPaths = AgentDetector.transcriptSearchPaths(home: home, name: "codex")
            #expect(codexPaths.contains(home + "/.codex/sessions"))
            #expect(codexPaths.contains(home + "/.codex/transcripts"))

            let cloudCodePaths = AgentDetector.transcriptSearchPaths(
                home: home, name: "cloudcode")
            #expect(cloudCodePaths.contains(home + "/.cloudcode"))
            #expect(cloudCodePaths.contains(home + "/.config/cloud-code"))
        }

        @Test("AgentDetector canonical process names")
        func agentDetectorProcessNames() {
            #expect(AgentDetector.canonicalName(forProcess: "cursor") == "cursor")
            #expect(AgentDetector.canonicalName(forProcess: "cursor-agent") == "cursor")
            #expect(AgentDetector.canonicalName(forProcess: "codex") == "codex")
            #expect(AgentDetector.canonicalName(forProcess: "codex-cli") == "codex")
            #expect(AgentDetector.canonicalName(forProcess: "cloudcode") == "cloudcode")
            #expect(AgentDetector.canonicalName(forProcess: "cloud-code") == "cloudcode")
            #expect(AgentDetector.canonicalName(forProcess: "windsurf") == "windsurf")
            #expect(AgentDetector.canonicalName(forProcess: "cascade") == "windsurf")
            #expect(AgentDetector.canonicalName(forProcess: "agy") == "antigravity")
            #expect(AgentDetector.canonicalName(forProcess: "antigravity") == "antigravity")
        }

        @Test("TaskDispatcher canonical aliases and routing")
        func taskDispatcherAliasesAndRouting() {
            #expect(TaskDispatcher.canonicalAgentAlias("cursor-agent") == "cursor")
            #expect(TaskDispatcher.canonicalAgentAlias("codex-cli") == "codex")
            #expect(TaskDispatcher.canonicalAgentAlias("cloud-code") == "cloudcode")
            #expect(TaskDispatcher.canonicalAgentAlias("windsurf-agent") == "windsurf")
            #expect(TaskDispatcher.canonicalAgentAlias("windsurf-ide") == "windsurf")
            #expect(TaskDispatcher.canonicalAgentAlias("github-copilot") == "copilot")
            #expect(TaskDispatcher.canonicalAgentAlias("antigravity-ide") == "antigravity")

            let prevSynthesis = StandaloneAgentDispatcher.enableInputSynthesis
            StandaloneAgentDispatcher.enableInputSynthesis = false
            defer { StandaloneAgentDispatcher.enableInputSynthesis = prevSynthesis }

            let cursorDispatch = TaskDispatcher.shared.dispatch(
                task: BantayTask(title: "Cursor review", assignedAgent: "cursor")
            )
            let codexDispatch = TaskDispatcher.shared.dispatch(
                task: BantayTask(title: "Codex run", assignedAgent: "codex")
            )
            let cloudCodeDispatch = TaskDispatcher.shared.dispatch(
                task: BantayTask(title: "CloudCode build", assignedAgent: "cloudcode")
            )
            #expect(cursorDispatch == "app:cursor")
            #expect(codexDispatch == "app:codex")
            #expect(cloudCodeDispatch == "app:cloudcode")
        }

        @Test("TaskDispatcher budget policy enforcement")
        func taskDispatcherBudgetPolicy() {
            // When limit enforcement is disabled, execution is always permitted
            #expect(
                TaskDispatcher.isDispatchAllowed(
                    cost: 50.0,
                    budget: 10.0,
                    enforceLimit: false
                )
            )
            // When enabled, cost exceeding budget is blocked
            #expect(
                !TaskDispatcher.isDispatchAllowed(
                    cost: 15.0,
                    budget: 10.0,
                    enforceLimit: true
                )
            )
            // Within budget is allowed
            #expect(
                TaskDispatcher.isDispatchAllowed(
                    cost: 5.0,
                    budget: 10.0,
                    enforceLimit: true
                )
            )
        }

        @Test("CodexUsageAdapter reads deep telemetry from SQLite database")
        func codexDeepTelemetryParsing() {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-test-\(UUID().uuidString)")
            let codexDir = tempDir.appendingPathComponent(".codex")
            try? FileManager.default.createDirectory(
                at: codexDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let dbPath = codexDir.appendingPathComponent("state_5.sqlite").path
            createMockCodexDB(at: dbPath)

            #expect(CodexUsageAdapter.detect(home: tempDir.path))
            let telemetry = CodexUsageAdapter.deepTelemetry(home: tempDir.path)
            #expect(telemetry != nil)
            #expect(telemetry?.totalTokensUsed == 15400)
            #expect(telemetry?.activeThreadCount == 1)
            #expect(telemetry?.latestThreadTitle == "Fix logic bug")
            #expect(telemetry?.latestModel == "gpt-4o")
            #expect((telemetry?.estimatedCostUSD ?? 0.0) > 0.0)

            // Test snapshot calculation
            let snap = CodexUsageAdapter.snapshot(
                since: 86_400 * 365,
                now: Date(timeIntervalSince1970: 1_780_000_001),
                home: tempDir.path
            )
            #expect(snap != nil)
            #expect((snap?.costUSD ?? 0.0) > 0.0)
            #expect(snap?.costBySource["codex"] != nil)
        }

        @Test("CursorUsageAdapter reads deep telemetry from ItemTable in state.vscdb")
        func cursorDeepTelemetryParsing() {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cursor-test-\(UUID().uuidString)")
            let globalDir = tempDir.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage")
            try? FileManager.default.createDirectory(
                at: globalDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let dbPath = globalDir.appendingPathComponent("state.vscdb").path
            createMockCursorDB(at: dbPath)

            #expect(CursorUsageAdapter.detect(home: tempDir.path))
            let telemetry = CursorUsageAdapter.deepTelemetry(home: tempDir.path)
            #expect(telemetry != nil)
            #expect(telemetry?.composerSuggestedLines == 1212)
            #expect(telemetry?.composerAcceptedLines == 340)
            #expect(telemetry?.contextUsagePercent == 78.614)
            #expect(telemetry?.totalLinesAdded == 1189)
            #expect(telemetry?.totalLinesRemoved == 28)
            #expect(telemetry?.filesChangedCount == 10)
            #expect(telemetry?.activeSessionName == "Test topic")
            #expect(telemetry?.unifiedMode == "agent")

            // Test snapshot calculation
            let snap = CursorUsageAdapter.snapshot(
                now: Date(),
                home: tempDir.path
            )
            #expect(snap != nil)
            #expect((snap?.costUSD ?? 0.0) > 0.0)
            #expect(snap?.costBySource["cursor"] != nil)

            // Local Cursor activity feeds Spend and Sessions, never the
            // Quotas view: line counts are usage, not a provider quota.
            let quotas = QuotaAxiTracker.probeLiveQuotas(
                activeProviders: ["cursor"],
                costUSD: 1.0,
                budgetUSD: 10.0,
                home: tempDir.path
            )
            #expect(quotas.first { $0.id == "cursor" } == nil)
        }

        @Test("ClaudeUsageAdapter parses statusLine rate limits and computes remaining quota")
        func claudeRateLimitsParsing() {
            let json = """
                {
                    "rate_limits": {
                        "five_hour": {
                            "used_percentage": 42.5,
                            "resets_at": 1780000000
                        },
                        "seven_day": {
                            "used_percentage": 18.0,
                            "resets_at": 1780500000
                        }
                    }
                }
                """
            let limits = ClaudeUsageAdapter.record(jsonString: json)
            #expect(limits != nil)
            #expect(limits?.fiveHour?.usedPercentage == 42.5)
            #expect(limits?.fiveHour?.resetsAt != nil)

            let quota = ClaudeUsageAdapter.quota()
            #expect(quota != nil)
            #expect(quota?.provider == "Claude Code")
            #expect(quota?.remainingPercent == 57.5)
            #expect(quota?.resetsAt != nil)
            #expect(
                quota?.usedDisplay.contains("43%") == true
                    || quota?.usedDisplay.contains("42%") == true)
        }

        @Test("OpenRouterUsageAdapter parses key response and limits")
        func openRouterKeyParsing() {
            let json = """
                {
                    "data": {
                        "label": "Workstation Key",
                        "usage": 15.00,
                        "limit": 60.00,
                        "is_free_tier": false
                    }
                }
                """
            let quota = OpenRouterUsageAdapter.parseKeyResponse(Data(json.utf8))
            #expect(quota != nil)
            #expect(quota?.provider == "OpenRouter")
            #expect(quota?.remainingPercent == 75.0)
            #expect(quota?.tier == "BYOK")
            #expect(quota?.usedDisplay.contains("$15.00") == true)
            #expect(quota?.totalDisplay.contains("$60.00 cap") == true)
        }

        @Test("OllamaUsageAdapter parses running models")
        func ollamaPsParsing() {
            let json = """
                {
                    "models": [
                        { "name": "llama3:latest", "model": "llama3:latest" },
                        { "name": "codellama:13b", "model": "codellama:13b" }
                    ]
                }
                """
            let quota = OllamaUsageAdapter.parsePsResponse(Data(json.utf8))
            #expect(quota != nil)
            #expect(quota?.provider == "Ollama")
            #expect(quota?.remainingPercent == 100.0)
            #expect(quota?.tier == "Local Models")
            #expect(quota?.usedDisplay.contains("2 running") == true)
        }

        @Test("dynamicResetDescription computes relative countdowns")
        func dynamicResetCountdown() {
            let now = Date()
            let resetIn90Min = now.addingTimeInterval(5400)
            let quota = ProviderQuota(
                provider: "Claude Code",
                remainingPercent: 50.0,
                resetsAt: resetIn90Min
            )
            let desc = quota.dynamicResetDescription(now: now)
            #expect(desc.contains("1h 30m"))

            let resetIn15Min = now.addingTimeInterval(900)
            let quota15 = ProviderQuota(
                provider: "Claude Code",
                remainingPercent: 50.0,
                resetsAt: resetIn15Min
            )
            #expect(quota15.dynamicResetDescription(now: now) == "Resets in 15m")

            let expiredQuota = ProviderQuota(
                provider: "Claude Code",
                remainingPercent: 50.0,
                resetsAt: now.addingTimeInterval(-60)
            )
            #expect(expiredQuota.dynamicResetDescription(now: now) == "Resets now")
        }

        @Test("TaskDispatcher resolves fallback agent when primary is critical or in cooldown")
        func taskDispatcherQuotaFailover() {
            let criticalClaude = ProviderQuota(
                provider: "Claude Code",
                remainingPercent: 4.0
            )
            let healthyCodex = ProviderQuota(
                provider: "OpenAI Codex",
                remainingPercent: 80.0
            )
            let quotas = [criticalClaude, healthyCodex]

            let resolution = TaskDispatcher.resolveQuotaAwareAgent(
                preferredAgent: "claude",
                quotas: quotas,
                quarantinedProviders: []
            )
            #expect(resolution.agent == "codex")
            #expect(resolution.reroutedFrom == "claude")

            let healthyClaude = ProviderQuota(
                provider: "Claude Code",
                remainingPercent: 90.0
            )
            let resolutionQuarantined = TaskDispatcher.resolveQuotaAwareAgent(
                preferredAgent: "claude",
                quotas: [healthyClaude, healthyCodex],
                quarantinedProviders: ["claude"]
            )
            #expect(resolutionQuarantined.agent == "codex")
            #expect(resolutionQuarantined.reroutedFrom == "claude")
        }

        @Test("promptCacheSavingsUSD computes 90% discount on cache reads")
        func promptCacheSavings() {
            var snapshot = UsageSnapshot()
            snapshot.inputTokens = 10_000
            snapshot.cacheReadTokens = 100_000
            #expect(abs(snapshot.promptCacheSavingsUSD - 0.27) < 0.001)
        }
    }

    private func createMockCodexDB(at path: String) {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return }
        let schema = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT,
                model TEXT,
                tokens_used INTEGER DEFAULT 0,
                updated_at_ms INTEGER
            );
            INSERT INTO threads (id, title, model, tokens_used, updated_at_ms)
            VALUES ('th_1', 'Fix logic bug', 'gpt-4o', 15400, 1780000000000);
            """
        sqlite3_exec(db, schema, nil, nil, nil)
        sqlite3_close(db)
    }

    private func createMockCursorDB(at path: String) {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return }
        let schema = """
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);
            INSERT INTO ItemTable (key, value) VALUES (
                'aiCodeTracking.dailyStats.v1.5.2026-06-29',
                '{"date":"2026-06-29","composerSuggestedLines":1212,"composerAcceptedLines":340,"tabSuggestedLines":0,"tabAcceptedLines":0}'
            );
            INSERT INTO ItemTable (key, value) VALUES (
                'composer.composerHeaders',
                '{"allComposers":[{"name":"Test topic","contextUsagePercent":78.614,"totalLinesAdded":1189,"totalLinesRemoved":28,"filesChangedCount":10,"lastUpdatedAt":1780000000000,"unifiedMode":"agent"}]}'
            );
            """
        sqlite3_exec(db, schema, nil, nil, nil)
        sqlite3_close(db)
    }
#endif
