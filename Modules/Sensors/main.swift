//
//  main.swift
//  Status
//

import Cocoa
import Kit

public class Sensors: Module {
    private var sensorsReader: SensorsReader?
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    
    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "\(self.config.name)_fanValue", defaultValue: "percentage")) ?? .percentage
    }
    
    private var selectedSensor: String
    
    /// Shown in the menu bar stack widget until the user picks sensors in settings.
    private static let defaultWidgetSensors: [String] = ["Average CPU", "Average GPU", "Fastest fan"]
    
    public init() {
        self.settingsView = Settings(.sensors)
        self.popupView = Popup()
        self.portalView = Portal(.sensors)
        self.notificationsView = Notifications(.sensors)
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: "Average CPU")
        
        super.init(
            moduleType: .sensors,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        self.sensorsReader = SensorsReader { [weak self] value in
            self?.usageCallback(value)
        }
        
        self.sensorsReader?.essentialKeys = { [weak self] in self?.essentialKeys() ?? [] }
        self.settingsView.setList(self.sensorsReader?.list.sensors)
        self.popupView.setup(self.sensorsReader?.list.sensors)
        self.portalView.setup(self.sensorsReader?.list.sensors)
        self.notificationsView.setup(self.sensorsReader?.list.sensors)
        
        self.settingsView.callback = { [weak self] in
            self?.sensorsReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.sensorsReader?.setInterval(value)
        }
        self.settingsView.HIDcallback = { [weak self] in
            DispatchQueue.global(qos: .background).async {
                self?.sensorsReader?.HIDCallback()
                DispatchQueue.main.async {
                    self?.popupView.setup(self?.sensorsReader?.list.sensors)
                    self?.portalView.setup(self?.sensorsReader?.list.sensors)
                    self?.settingsView.setList(self?.sensorsReader?.list.sensors)
                    self?.notificationsView.setup(self?.sensorsReader?.list.sensors)
                }
            }
        }
        self.settingsView.unknownCallback = { [weak self] in
            DispatchQueue.global(qos: .background).async {
                self?.sensorsReader?.unknownCallback()
                DispatchQueue.main.async {
                    self?.popupView.setup(self?.sensorsReader?.list.sensors)
                    self?.portalView.setup(self?.sensorsReader?.list.sensors)
                    self?.settingsView.setList(self?.sensorsReader?.list.sensors)
                    self?.notificationsView.setup(self?.sensorsReader?.list.sensors)
                }
            }
        }
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: self.selectedSensor)
        self.settingsView.selectedHandler = { [weak self] value in
            self?.selectedSensor = value
            self?.sensorsReader?.read()
        }
        
        self.setReaders([self.sensorsReader])
    }
    
    public override func willTerminate() {
        CoolingController.shared.release((self.sensorsReader?.list.sensors ?? []).compactMap { $0 as? Fan }.filter { !$0.isComputed })
        guard SMCHelper.shared.isActive(), let reader = self.sensorsReader else { return }
        
        reader.list.sensors.filter({ $0 is Fan }).forEach { (s: Sensor_p) in
            if let f = s as? Fan, let mode = f.customMode {
                if !mode.isAutomatic {
                    SMCHelper.shared.setFanMode(f.id, mode: FanMode.automatic.rawValue)
                }
            }
        }
    }
    
    /// Average CPU and GPU temperatures in Celsius (or the SoC average on chips without separate sensors).
    private static func averageTemperatures(_ sensors: [Sensor_p]) -> [Double] {
        let value: (String) -> Double? = { key in
            guard let s = sensors.first(where: { $0.key == key }), s.value > 0 else { return nil }
            return s.value
        }
        let list = [value("Average CPU"), value("Average GPU")].compactMap { $0 }
        if list.isEmpty, let soc = value("Average SOC") { return [soc] }
        return list
    }
    
    /// Average CPU and GPU temperature for the two-row widget; falls back to the SoC average
    /// when a chip only exposes combined sensors.
    private static func temperatureRows(_ sensors: [Sensor_p], fan showFan: Bool, fanValue: FanValue) -> [TemperatureRow] {
        let row: (String, String) -> TemperatureRow? = { label, key in
            guard let s = sensors.first(where: { $0.key == key }), s.value > 0 else { return nil }
            return TemperatureRow(label: label, value: s.formattedMiniValue, celsius: s.value)
        }
        var rows = [row("CPU", "Average CPU"), row("GPU", "Average GPU")].compactMap { $0 }
        if rows.isEmpty, let soc = row("SoC", "Average SOC") {
            rows = [soc]
        }
        
        // fastest fan when there are several, otherwise the only one; Macs without fans show nothing
        if showFan, let fan = (sensors.first(where: { $0.key == "Fastest fan" }) ?? sensors.first(where: { $0 is Fan && !$0.isComputed })) as? Fan {
            let percentage = Double(fan.percentage)
            let value = fanValue == .percentage ? "\(fan.percentage)%" : fan.formattedMiniValue
            rows.append(TemperatureRow(label: "FAN", value: value, severity: Severity.usage(percentage / 100)))
        }
        return rows
    }
    
    /// Sensors something currently depends on while the popup/settings are closed.
    private func essentialKeys() -> Set<String> {
        let sensors = self.sensorsReader?.list.sensors ?? []
        var keys = Set(sensors.filter({ !$0.notificationThreshold.isEmpty }).map({ $0.key }))
        // health monitoring and cooling mode always need the CPU/GPU averages
        keys.formUnion(["Average CPU", "Average GPU", "Average SOC"])
        if CoolingController.isEnabled {
            keys.formUnion(sensors.filter({ $0 is Fan && !$0.isComputed }).map({ $0.key }))
        }
        for w in self.menuBar.widgets where w.isActive {
            switch w.item {
            case is Mini:
                keys.insert(self.selectedSensor)
            case is StackWidget:
                let selected = sensors.filter({ $0.state }).map({ $0.key })
                keys.formUnion(selected.isEmpty ? Sensors.defaultWidgetSensors : selected)
            case is BarChart:
                keys.formUnion(["Average CPU", "Average GPU", "Average SOC"])
            case let widget as TemperaturesWidget:
                keys.formUnion(["Average CPU", "Average GPU", "Average SOC"])
                if widget.showsFan {
                    keys.insert("Fastest fan")
                    keys.formUnion(sensors.filter({ $0 is Fan && !$0.isComputed }).map({ $0.key }))
                }
            default:
                break
            }
        }
        return keys
    }
    
    private func usageCallback(_ raw: Sensors_List?) {
        guard let value = raw, self.enabled else { return }
        if let cpu = value.sensors.first(where: { $0.key == "Average CPU" }) ?? value.sensors.first(where: { $0.key == "Average SOC" }), cpu.value > 0 {
            HealthMonitor.shared.report(.cpuTemperature, cpu.value)
        }
        if let gpu = value.sensors.first(where: { $0.key == "Average GPU" }), gpu.value > 0 {
            HealthMonitor.shared.report(.gpuTemperature, gpu.value)
        }
        let cpuTemperature = (value.sensors.first(where: { $0.key == "Average CPU" }) ?? value.sensors.first(where: { $0.key == "Average SOC" }))?.value
        CoolingController.shared.update(cpuTemperature: cpuTemperature, fans: value.sensors.compactMap { $0 as? Fan }.filter { !$0.isComputed })
        
        self.popupView.usageCallback(value.sensors)
        self.portalView.usageCallback(value.sensors)
        self.notificationsView.usageCallback(value.sensors)
        
        let activeWidgets = self.menuBar.widgets.filter{ $0.isActive }
        self.sensorsReader?.sleepMode(state: activeWidgets.contains(where: {$0.item is Label}) && activeWidgets.count == 1)
        
        activeWidgets.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                if let active = value.sensors.first(where: { $0.key == self.selectedSensor }) {
                    var value: Double = active.localValue/100
                    var unit: String = active.miniUnit
                    if let fan = active as? Fan, self.fanValueState == .percentage {
                        value = Double(fan.percentage)/100
                        unit = "%"
                    }
                    if value > 999 {
                        unit = ""
                    }
                    // the widget value is "local value / 100", so express the 75 °C / 90 °C warning points the same way
                    if active.type == .temperature && !(active is Fan) {
                        let toLocal: (Double) -> Double = {
                            Measurement(value: $0, unit: UnitTemperature.celsius).converted(to: UnitTemperature.current).value / 100
                        }
                        widget.setColorZones((toLocal(75), toLocal(90)))
                    } else {
                        widget.setColorZones((0.6, 0.8))
                    }
                    widget.setValue(value)
                    widget.setSuffix(unit)
                }
            case let widget as TemperaturesWidget:
                widget.setValues(Sensors.temperatureRows(value.sensors, fan: widget.showsFan, fanValue: self.fanValueState))
            case let widget as StackWidget:
                // nothing ticked in settings yet: fall back to useful defaults instead of an empty widget
                var selected = value.sensors.filter { $0.state }
                if selected.isEmpty {
                    selected = Sensors.defaultWidgetSensors.compactMap { key in
                        value.sensors.first(where: { $0.key == key })
                    }
                }
                
                let list: [Stack_t] = selected.map { (s: Sensor_p) in
                    var value = s.formattedMiniValue
                    if let f = s as? Fan, self.fanValueState == .percentage {
                        value = "\(f.percentage)%"
                    }
                    return Stack_t(key: s.key, value: value)
                }
                
                widget.setValues(list)
            case let widget as BarChart:
                // one bar per average temperature (CPU, GPU), scaled to 0–100 °C
                let colorCoded = widget.colorState == .utilization
                let bars: [[ColorValue]] = Sensors.averageTemperatures(value.sensors).map { celsius in
                    [ColorValue(min(max(celsius / 100, 0), 1), color: colorCoded ? Severity.temperature(celsius).color : nil)]
                }
                widget.setValue(bars)
            default: break
            }
        }
    }
}
