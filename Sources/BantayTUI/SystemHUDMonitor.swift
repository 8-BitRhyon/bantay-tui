import AppKit
import Combine
import CoreAudio
import Foundation
import IOKit.ps

public enum HUDType: Equatable, Sendable {
    case volume(Float, isMuted: Bool)
    case brightness(Float)
    case battery(level: Int, isCharging: Bool)

    public var iconName: String {
        switch self {
        case .volume(_, let isMuted):
            return isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness:
            return "sun.max.fill"
        case .battery(_, let isCharging):
            return isCharging ? "battery.100.bolt" : "battery.100"
        }
    }

    public var percentage: Float {
        switch self {
        case .volume(let val, _): return val
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
    private var lastVolume: Float = -1
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
                self?.checkVolumeState()
            }
        }
        checkBatteryState()
        checkVolumeState()
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

    public func checkVolumeState() {
        guard ApprovalNotificationController.hasBundleProxy else { return }
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )

        guard status == noErr else { return }

        var volume: Float32 = 0.0
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let volStatus = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &volumeAddress,
            0,
            nil,
            &volumeSize,
            &volume
        )

        if volStatus == noErr {
            if lastVolume >= 0 && abs(volume - lastVolume) > 0.01 {
                showHUD(.volume(volume, isMuted: volume == 0))
            }
            lastVolume = volume
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
