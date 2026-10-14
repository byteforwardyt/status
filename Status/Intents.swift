//
//  Intents.swift
//  Status
//

import AppIntents
import Kit

// Siri & Shortcuts. Answers come from the readings Status is already collecting.

@available(macOS 13.0, *)
private func reading(_ metric: HealthMetric) -> String {
    guard let value = HealthMonitor.shared.value(metric, maxAge: metric == .diskFree || metric == .batteryHealth ? 3600 : 120) else {
        return localizedString("Status doesn't have a recent reading for that. Make sure the module is turned on.")
    }
    return metric.format(value)
}

@available(macOS 13.0, *)
struct MacTemperatureIntent: AppIntent {
    static var title: LocalizedStringResource = "Mac Temperature"
    static var description = IntentDescription("Average CPU and GPU temperature.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        var parts = ["CPU \(reading(.cpuTemperature))"]
        if HealthMonitor.shared.value(.gpuTemperature) != nil {
            parts.append("GPU \(reading(.gpuTemperature))")
        }
        let text = parts.joined(separator: ", ")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

@available(macOS 13.0, *)
struct CPUUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "CPU Usage"
    static var description = IntentDescription("Current CPU usage.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = "CPU \(reading(.cpuUsage))"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

@available(macOS 13.0, *)
struct MemoryUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Memory Usage"
    static var description = IntentDescription("Memory usage and pressure.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = "\(localizedString("Memory")) \(reading(.memoryUsage)), \(localizedString("pressure")) \(reading(.memoryPressure))"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

@available(macOS 13.0, *)
struct MacHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "Mac Health"
    static var description = IntentDescription("Overall health of your Mac and anything that needs attention.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let insights = InsightEngine.current()
        let text: String
        if insights.isEmpty {
            text = localizedString("Your Mac is doing fine. Nothing needs your attention.")
        } else {
            text = insights.prefix(3).map { "\($0.headline). \($0.detail)" }.joined(separator: "\n")
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

@available(macOS 13.0, *)
struct StatusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MacHealthIntent(), phrases: ["How is my Mac doing in \(.applicationName)", "Check my Mac with \(.applicationName)"],
                    shortTitle: "Mac Health", systemImageName: "heart.text.square")
        AppShortcut(intent: MacTemperatureIntent(), phrases: ["How hot is my Mac in \(.applicationName)", "Mac temperature in \(.applicationName)"],
                    shortTitle: "Temperature", systemImageName: "thermometer.medium")
        AppShortcut(intent: CPUUsageIntent(), phrases: ["CPU usage in \(.applicationName)"],
                    shortTitle: "CPU Usage", systemImageName: "cpu")
        AppShortcut(intent: MemoryUsageIntent(), phrases: ["Memory usage in \(.applicationName)"],
                    shortTitle: "Memory Usage", systemImageName: "memorychip")
    }
}
