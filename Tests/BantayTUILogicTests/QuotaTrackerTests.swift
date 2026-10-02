#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @Suite("Provider Quota and GUI Agent Detection", .serialized)
    struct QuotaTrackerTests {
        @Test("probeLiveQuotas generates expected provider profiles for all providers")
        func liveQuotaGeneration() {
            let active = [
                "codex", "cursor", "cloudcode", "claude",
                "antigravity", "windsurf", "kilo",
            ]
            let quotas = QuotaAxiTracker.probeLiveQuotas(
                activeProviders: active,
                costUSD: 2.50,
                budgetUSD: 10.00,
                burnRateTPM: 120.0
            )

            #expect(!quotas.isEmpty)
            let ids = Set(quotas.map(\.id))
            #expect(ids.contains("claude"))
            #expect(ids.contains("codex"))
            #expect(ids.contains("cursor"))
            #expect(ids.contains("cloudcode"))
            #expect(ids.contains("antigravity"))
            #expect(ids.contains("windsurf"))
            #expect(ids.contains("kilo"))

            // Verify Claude profile
            if let claude = quotas.first(where: { $0.id == "claude" }) {
                #expect(claude.provider == "Claude Code")
                #expect(claude.resetHint == "5h rolling window")
                #expect(claude.tier == "Pro Plan")
                #expect(claude.usedDisplay.contains("$2.50"))
                #expect(claude.totalDisplay.contains("$10.00 cap"))
                #expect(claude.hoursRemaining != nil)
            }

            // Verify Codex profile
            if let codex = quotas.first(where: { $0.id == "codex" }) {
                #expect(codex.provider == "OpenAI Codex")
                #expect(codex.resetHint == "Midnight UTC")
                #expect(codex.tier.contains("Tier 1"))
                #expect(codex.totalDisplay == "$20.00 / mo")
            }

            // Verify Cursor profile
            if let cursor = quotas.first(where: { $0.id == "cursor" }) {
                #expect(cursor.provider == "Cursor")
                #expect(cursor.resetHint == "Renews 1st of month")
                #expect(cursor.tier.contains("500 Fast Reqs"))
                #expect(cursor.totalDisplay == "500 Fast / mo")
                #expect(cursor.usedDisplay.contains("500 reqs"))
            }

            // Verify Cloud Code profile
            if let cloud = quotas.first(where: { $0.id == "cloudcode" }) {
                #expect(cloud.provider == "Google Cloud Code")
                #expect(cloud.resetHint == "Midnight PST")
                #expect(cloud.tier.contains("1.5k RPD"))
                #expect(cloud.totalDisplay == "1,500 RPD")
            }

            // Verify Antigravity profile
            if let agy = quotas.first(where: { $0.id == "antigravity" }) {
                #expect(agy.provider == "Antigravity")
                #expect(agy.resetHint == "Session Budget")
                #expect(agy.tier == "Local Session")
                #expect(agy.totalDisplay.contains("$10.00"))
            }

            // Verify Windsurf profile
            if let wind = quotas.first(where: { $0.id == "windsurf" }) {
                #expect(wind.provider == "Windsurf")
                #expect(wind.resetHint == "Monthly")
                #expect(wind.tier == "Cascade Pro")
                #expect(wind.totalDisplay == "500 Prompts")
            }

            // Verify Kilo profile
            if let kilo = quotas.first(where: { $0.id == "kilo" }) {
                #expect(kilo.provider == "Kilo")
                #expect(kilo.resetHint == "Continuous Ledger")
                #expect(kilo.tier == "Pay-as-you-go")
                #expect(kilo.totalDisplay == "Prepaid")
            }
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

        @Test("overBudgetSpend clamps remaining percentage safely without crash")
        func overBudgetSpend() {
            let quotas = QuotaAxiTracker.probeLiveQuotas(
                activeProviders: ["claude", "antigravity"],
                costUSD: 25.00,
                budgetUSD: 10.00,
                burnRateTPM: 100.0
            )
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

            // Malformed JSON falls back gracefully without crash
            let fallbackMalformed = QuotaAxiTracker.parseQuotaJSON("{ not valid json }")
            #expect(!fallbackMalformed.isEmpty)

            // Empty string falls back gracefully
            let fallbackEmpty = QuotaAxiTracker.parseQuotaJSON("")
            #expect(!fallbackEmpty.isEmpty)
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

            // Verify live quota probe integrates deep telemetry
            let quotas = QuotaAxiTracker.probeLiveQuotas(
                activeProviders: ["cursor"],
                costUSD: 1.0,
                budgetUSD: 10.0,
                home: tempDir.path
            )
            let cursorQuota = quotas.first { $0.id == "cursor" }
            #expect(cursorQuota != nil)
            #expect(cursorQuota?.usedDisplay.contains("1189 lines") == true)
            #expect(cursorQuota?.tier.contains("Agent") == true)
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
