//
//  Temperatures.swift
//  Status
//

import Cocoa

public struct TemperatureRow: Equatable {
    public let label: String
    public let value: String
    /// Health of the value, used for color coding.
    public let severity: Severity?

    public init(label: String, value: String, severity: Severity?) {
        self.label = label
        self.value = value
        self.severity = severity
    }

    public init(label: String, value: String, celsius: Double?) {
        self.init(label: label, value: value, severity: celsius.map { Severity.temperature($0) })
    }
}

/// Compact menu bar widget with labelled, color-coded readings stacked two per column
/// (e.g. "CPU 62°" over "GPU 58°", then "FAN 37%").
public class TemperaturesWidget: WidgetWrapper {
    private var rows: [TemperatureRow] = []
    private var colorState: Bool = true
    private var fanState: Bool = false
    private let textCache = WidgetTextCache(limit: 64)

    /// Whether the fan reading should be shown; read by the module when building rows.
    public var showsFan: Bool { self.queue.sync { self.fanState } }

    public init(title: String, preview: Bool = false) {
        if preview {
            self.rows = [
                TemperatureRow(label: "CPU", value: "58°", celsius: 58),
                TemperatureRow(label: "GPU", value: "49°", celsius: 49)
            ]
        }

        super.init(.temperatures, title: title, frame: CGRect(
            x: 0,
            y: Constants.Widget.margin.y,
            width: 46,
            height: Constants.Widget.height - (2*Constants.Widget.margin.y)
        ))

        self.canDrawConcurrently = true

        if !preview {
            self.colorState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_color", defaultValue: self.colorState)
            self.fanState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_fan", defaultValue: self.fanState)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setValues(_ rows: [TemperatureRow]) {
        let updated = self.queue.sync { () -> Bool in
            guard self.rows != rows else { return false }
            self.rows = rows
            return true
        }
        guard updated else { return }
        DispatchQueue.main.async(execute: {
            self.needsDisplay = true
        })
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        var rows: [TemperatureRow] = []
        var colored = true
        self.queue.sync {
            rows = self.rows
            colored = self.colorState
        }
        colored = colored && Severity.isEnabled

        guard !rows.isEmpty else {
            self.setWidth(0)
            return
        }

        let twoRows = rows.count > 1
        let labelFont = NSFont.systemFont(ofSize: twoRows ? 7.5 : 9, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: twoRows ? 10 : 12, weight: .medium)
        let rowHeight = twoRows ? self.frame.height / 2 : self.frame.height
        let margin: CGFloat = 2
        let gap: CGFloat = 3
        let columnGap: CGFloat = 7

        // two readings per column: CPU over GPU, then FAN
        let columns = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
        var x: CGFloat = margin

        for (c, column) in columns.enumerated() {
            // resolve against the menu bar's current appearance; a pre-faded dynamic color can resolve to black
            let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let labelColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.6)
            let labels = column.map { row in
                self.textCache.entry(row.label, key: "label|\(twoRows)|\(dark)") {
                    [.font: labelFont, .foregroundColor: labelColor]
                }
            }
            let values = column.map { row -> WidgetTextCache.Entry in
                let color: NSColor = colored ? (row.severity?.color ?? .textColor) : .textColor
                return self.textCache.entry(row.value, key: "value|\(twoRows)|\(color.hexString)") {
                    [.font: valueFont, .foregroundColor: color]
                }
            }
            let labelWidth = (labels.map { $0.width }.max() ?? 0).rounded(.up)
            let valueWidth = max(values.map { $0.width }.max() ?? 0, 18).rounded(.up)
            let centered = !twoRows || column.count == 1 // a lone reading sits in the middle

            for (i, (label, value)) in zip(labels, values).enumerated() {
                let y: CGFloat = centered ? (twoRows ? rowHeight / 2 : 0) : (i == 0 ? rowHeight : 0)
                let labelY = y + (rowHeight - labelFont.capHeight) / 2 - (twoRows ? 1.5 : 2)
                let valueY = y + (rowHeight - valueFont.capHeight) / 2 - (twoRows ? 2.5 : 3)
                label.string.draw(at: NSPoint(x: x, y: labelY))
                value.string.draw(at: NSPoint(x: x + labelWidth + gap + valueWidth - value.width, y: valueY))
            }

            x += labelWidth + gap + valueWidth
            if c < columns.count - 1 { x += columnGap }
        }

        let width = x + margin
        guard abs(self.frame.width - width) > 1 else { return }
        self.setWidth(width)
    }

    // MARK: - Settings

    public override func settings() -> NSView {
        let view = SettingsContainerView()

        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(
                localizedString("Color-coded values"),
                localizedString("Green, yellow, orange and red for good to critical"),
                component: switchView(action: #selector(self.toggleColor), state: self.colorState)
            ),
            PreferencesRow(
                localizedString("Show fan speed"),
                localizedString("Fastest fan, next to the temperatures"),
                component: switchView(action: #selector(self.toggleFan), state: self.fanState)
            )
        ]))

        return view
    }

    @objc private func toggleColor(_ sender: NSControl) {
        let state = controlState(sender)
        self.queue.sync { self.colorState = state }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_color", value: state)
        self.display()
    }

    @objc private func toggleFan(_ sender: NSControl) {
        let state = controlState(sender)
        self.queue.sync { self.fanState = state }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_fan", value: state)
    }
}
