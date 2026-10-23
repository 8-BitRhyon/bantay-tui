import Foundation

/// OpenCode Go plan limits. Go meters usage in dollars per model across
/// three rolling windows: 5-hour (20% of the monthly limit), weekly (50%),
/// and monthly (100%). Source: opencode.ai/v2/docs/console/go, October 2026.
/// Limits change without notice; rows are labelled as locally computed.
public enum OpenCodeGoLimits {
    public enum Plan: String, Sendable {
        case go
        case goPlus

        public var displayName: String {
            switch self {
            case .go: return "Go $10/mo"
            case .goPlus: return "Go Plus $40/mo"
            }
        }
    }

    public enum Window: Sendable {
        case fiveHour
        case weekly
        case monthly

        public var fraction: Double {
            switch self {
            case .fiveHour: return 0.2
            case .weekly: return 0.5
            case .monthly: return 1.0
            }
        }

        public var label: String {
            switch self {
            case .fiveHour: return "5h"
            case .weekly: return "weekly"
            case .monthly: return "monthly"
            }
        }
    }

    public struct ModelLimit: Sendable {
        let displayName: String
        let goMonthlyUSD: Double
        let goPlusMonthlyUSD: Double

        public func monthlyUSD(plan: Plan) -> Double {
            plan == .goPlus ? goPlusMonthlyUSD : goMonthlyUSD
        }
    }

    /// Normalized model id (lowercased, alphanumeric only) to limits.
    public static let models: [String: ModelLimit] = [
        "glm53flash": ModelLimit(
            displayName: "GLM-5.3-Flash", goMonthlyUSD: 60, goPlusMonthlyUSD: 180),
        "glm53": ModelLimit(displayName: "GLM-5.3", goMonthlyUSD: 15, goPlusMonthlyUSD: 120),
        "glm52": ModelLimit(displayName: "GLM-5.2", goMonthlyUSD: 60, goPlusMonthlyUSD: 180),
        "kimik3": ModelLimit(displayName: "Kimi K3", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "kimik27code": ModelLimit(
            displayName: "Kimi K2.7 Code", goMonthlyUSD: 60, goPlusMonthlyUSD: 180),
        "longcat20": ModelLimit(
            displayName: "LongCat-2.0", goMonthlyUSD: 60, goPlusMonthlyUSD: 240),
        "step5preview": ModelLimit(
            displayName: "Step 5 Preview", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "mimov26flash": ModelLimit(
            displayName: "MiMo-V2.6-Flash", goMonthlyUSD: 60, goPlusMonthlyUSD: 120),
        "mimov26pro": ModelLimit(
            displayName: "MiMo-V2.6-Pro", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "mimov25": ModelLimit(displayName: "MiMo-V2.5", goMonthlyUSD: 60, goPlusMonthlyUSD: 120),
        "mimov25pro": ModelLimit(
            displayName: "MiMo-V2.5-Pro", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "minimaxm31flash": ModelLimit(
            displayName: "MiniMax M3.1 Flash", goMonthlyUSD: 20, goPlusMonthlyUSD: 80),
        "minimaxm3": ModelLimit(displayName: "MiniMax M3", goMonthlyUSD: 60, goPlusMonthlyUSD: 180),
        "musespark13contributor": ModelLimit(
            displayName: "Muse Spark 1.3", goMonthlyUSD: 60, goPlusMonthlyUSD: 120),
        "musespark12contributor": ModelLimit(
            displayName: "Muse Spark 1.2", goMonthlyUSD: 60, goPlusMonthlyUSD: 120),
        "qwen38max": ModelLimit(displayName: "Qwen3.8 Max", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "qwen38flash": ModelLimit(
            displayName: "Qwen3.8 Flash", goMonthlyUSD: 30, goPlusMonthlyUSD: 90),
        "qwen37plus": ModelLimit(
            displayName: "Qwen3.7 Plus", goMonthlyUSD: 60, goPlusMonthlyUSD: 180),
        "deepseekv41flash": ModelLimit(
            displayName: "DeepSeek V4.1 Flash", goMonthlyUSD: 80, goPlusMonthlyUSD: 160),
        "deepseekv4pro": ModelLimit(
            displayName: "DeepSeek V4 Pro", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "hy4preview": ModelLimit(
            displayName: "Hy4 preview", goMonthlyUSD: 30, goPlusMonthlyUSD: 120),
        "hy3": ModelLimit(displayName: "Hy3", goMonthlyUSD: 60, goPlusMonthlyUSD: 240),
        "grok47": ModelLimit(displayName: "Grok 4.7", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "gpt6luna": ModelLimit(displayName: "GPT 6 Luna", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "gpt56luna": ModelLimit(
            displayName: "GPT 5.6 Luna", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "claudehaiku55": ModelLimit(
            displayName: "Claude Haiku 5.5", goMonthlyUSD: 15, goPlusMonthlyUSD: 60),
        "gemini4argoncontributor": ModelLimit(
            displayName: "Gemini 4 Argon", goMonthlyUSD: 60, goPlusMonthlyUSD: 240),
    ]

    public static func normalizeModelID(_ id: String) -> String {
        id.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func limit(for modelID: String, plan: Plan) -> ModelLimit? {
        models[normalizeModelID(modelID)]
    }

    /// The tightest allowance window for measured spend: highest fraction of
    /// its allowance consumed. Returns spend, allowance, and window.
    public static func tightestWindow(
        spend5h: Double, spend7d: Double, spend30d: Double, monthlyLimit: Double
    ) -> (spend: Double, allowance: Double, window: Window) {
        let candidates: [(Window, Double)] = [
            (.fiveHour, spend5h), (.weekly, spend7d), (.monthly, spend30d),
        ]
        var best: (spend: Double, allowance: Double, window: Window) = (
            spend30d, monthlyLimit, .monthly
        )
        for (window, spend) in candidates {
            let allowance = monthlyLimit * window.fraction
            guard allowance > 0 else { continue }
            let bestAllowance = best.allowance > 0 ? best.allowance : monthlyLimit
            if spend / allowance > best.spend / bestAllowance {
                best = (spend, allowance, window)
            }
        }
        return best
    }

    public static func remainingPercent(spend: Double, allowance: Double) -> Double {
        guard allowance > 0 else { return 100 }
        return min(max((1 - spend / allowance) * 100, 0), 100)
    }
}
