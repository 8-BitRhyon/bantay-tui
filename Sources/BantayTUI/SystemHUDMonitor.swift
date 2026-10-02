import AppKit
import Combine
import Foundation
import IOKit.ps

public enum HUDType: Equatable, Sendable {
    case brightness(Float)
    case battery(level: Int, isCharging: Bool)

    public var iconName: String {
        switch self {
        case .brightness:
            return "sun.max.fill"
        case .battery(_, let isCharging):
            return isCharging ? "battery.100.bolt" : "battery.100"
        }
    }

    public var percentage: Float {
        switch self {
        case .brightness(let val): return val
        case .battery(let level, _): return Float(level) / 100.0
        }
    }
}

public struct HUDPayload: Equatable, Sendable {
    public let type: HUDType
    public let timestamp: Date = Date()
}

@MainActor
public final class SystemHUDMonitor: ObservableObject {
    public static let shared = SystemHUDMonitor()

    @Published public private(set) var activeHUD: HUDPayload?

    private var pollTimer: Timer?
    private var dismissTask: Task<Void, Never>?
    private var lastCharging: Bool = false

    private init() {
        startMonitoring()
    }

    public func startMonitoring() {
        guard ApprovalNotificationController.hasBundleProxy else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkBatteryState()
            }
        }
        checkBatteryState()
    }

    public func showHUD(_ type: HUDType) {
        activeHUD = HUDPayload(type: type)
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            activeHUD = nil
        }
    }

    public func checkBatteryState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return
        }

        for source in sources {
            guard
                let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any]
            else {
                continue
            }

            let isCharging = (info[kIOPSIsChargingKey] as? Bool) ?? false
            let currentCapacity = (info[kIOPSCurrentCapacityKey] as? Int) ?? 100
            let maxCapacity = (info[kIOPSMaxCapacityKey] as? Int) ?? 100
            let level = Int((Float(currentCapacity) / Float(maxCapacity)) * 100.0)

            if isCharging != lastCharging {
                showHUD(.battery(level: level, isCharging: isCharging))
                lastCharging = isCharging
            }
        }
    }
}
