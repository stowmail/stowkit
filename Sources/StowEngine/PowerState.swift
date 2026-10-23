import Foundation
import IOKit.ps

/// Whether the Mac is on battery, how full it is, and whether Low Power Mode
/// is on. Background sync pauses on battery below 20 per cent and whenever
/// Low Power Mode is on (D-037).
public struct PowerState: Sendable, Equatable {
    public var onBattery: Bool
    /// Charge in per cent, when there is a battery.
    public var batteryPercent: Int?
    public var lowPowerMode: Bool

    public init(onBattery: Bool, batteryPercent: Int?, lowPowerMode: Bool) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
    }

    public static let batteryThreshold = 20

    /// Why sync should pause now, in plain words, or nil to carry on.
    public var pauseReason: String? {
        if lowPowerMode { return "Low Power Mode is on" }
        if onBattery, let percent = batteryPercent, percent < Self.batteryThreshold {
            return "on battery at \(percent) per cent (below \(Self.batteryThreshold))"
        }
        return nil
    }

    /// Reads the current state from IOKit. A desktop Mac has no battery and never pauses for it.
    public static func current() -> PowerState {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: lowPower) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var percent: Int?
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            percent = current * 100 / maximum
        }
        return PowerState(onBattery: providing == kIOPSBatteryPowerValue, batteryPercent: percent, lowPowerMode: lowPower)
    }
}
