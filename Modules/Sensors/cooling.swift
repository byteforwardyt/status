//
//  cooling.swift
//  Status
//

import Foundation
import Kit

/// Cooling mode: runs every fan at full speed while the CPU is above a chosen temperature,
/// then hands control back to macOS once it has cooled by a few degrees.
internal final class CoolingController {
    static let shared = CoolingController()
    
    static let thresholds: [Int] = [70, 75, 80, 85, 90]
    private let hysteresis: Double = 8
    private var boosting: Bool = false
    
    static var isEnabled: Bool {
        get { Store.shared.bool(key: "Sensors_cooling", defaultValue: false) }
        set { Store.shared.set(key: "Sensors_cooling", value: newValue) }
    }
    static var threshold: Int {
        get { Store.shared.int(key: "Sensors_coolingThreshold", defaultValue: 80) }
        set { Store.shared.set(key: "Sensors_coolingThreshold", value: newValue) }
    }
    
    var isBoosting: Bool { self.boosting }
    
    func update(cpuTemperature: Double?, fans: [Fan]) {
        guard !fans.isEmpty else { return }
        guard CoolingController.isEnabled, let temp = cpuTemperature else {
            if self.boosting { self.release(fans) }
            return
        }
        let limit = Double(CoolingController.threshold)
        if !self.boosting && temp >= limit {
            guard SMCHelper.shared.isInstalled else { return }
            self.boosting = true
            fans.forEach { fan in
                SMCHelper.shared.setFanMode(fan.id, mode: FanMode.forced.rawValue)
                SMCHelper.shared.setFanSpeed(fan.id, speed: Int(fan.maxSpeed))
            }
            HistoryStore.shared.record(event: "\(localizedString("Cooling mode")): \(localizedString("fans to full speed")) (\(temperature(temp)))", severity: .warning)
        } else if self.boosting && temp <= limit - self.hysteresis {
            self.release(fans)
        }
    }
    
    func release(_ fans: [Fan]) {
        guard self.boosting else { return }
        self.boosting = false
        fans.forEach { SMCHelper.shared.setFanMode($0.id, mode: FanMode.automatic.rawValue) }
    }
}
