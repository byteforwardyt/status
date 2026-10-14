//
//  History.swift
//  Status
//

import Cocoa
import Kit

/// Settings page: 24 h / 7 day timeline per metric, alerts that fired, and data used per app.
final class HistoryView: NSStackView {
    private let metricPicker = NSPopUpButton()
    private let rangePicker = NSSegmentedControl(labels: [localizedString("24 hours"), localizedString("7 days")], trackingMode: .selectOne, target: nil, action: nil)
    private let chart = HistoryChartView()
    private let averageTile = StatTile()
    private let peakTile = StatTile()
    private let nowTile = StatTile()
    private let eventsSection = PreferencesSection(title: localizedString("Alerts & events"))
    private let appsSection = PreferencesSection(title: localizedString("Data by app"))
    private let appsRange = NSSegmentedControl(labels: [localizedString("Today"), localizedString("7 days"), localizedString("30 days")], trackingMode: .selectOne, target: nil, action: nil)
    private var eventRows: [NSView] = []
    private var appRows: [NSView] = []

    private var metric: HealthMetric = .cpuUsage
    private var interval: TimeInterval { self.rangePicker.selectedSegment == 1 ? 7 * 86400 : 86400 }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Settings.width, height: Constants.Settings.height))
        self.translatesAutoresizingMaskIntoConstraints = false

        let scroll = ScrollableStackView(orientation: .vertical)
        scroll.stackView.edgeInsets = NSEdgeInsets(top: 0, left: Constants.Settings.margin, bottom: Constants.Settings.margin, right: Constants.Settings.margin)
        scroll.stackView.spacing = Constants.Settings.margin

        // controls
        HealthMetric.charted.forEach { m in
            self.metricPicker.addItem(withTitle: m.title)
            self.metricPicker.lastItem?.representedObject = m.rawValue
        }
        self.metricPicker.target = self
        self.metricPicker.action = #selector(self.changeMetric)
        self.rangePicker.selectedSegment = 0
        self.rangePicker.target = self
        self.rangePicker.action = #selector(self.reload)
        let controls = NSStackView(views: [self.metricPicker, NSView(), self.rangePicker])
        controls.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 0, right: 4)
        scroll.stackView.addArrangedSubview(controls)

        // chart card
        let chartCard = PreferencesSection([self.chart])
        self.chart.heightAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.stackView.addArrangedSubview(chartCard)

        // summary tiles
        let tiles = NSStackView(views: [self.averageTile, self.peakTile, self.nowTile])
        tiles.distribution = .fillEqually
        tiles.spacing = Constants.Settings.margin
        scroll.stackView.addArrangedSubview(tiles)

        scroll.stackView.addArrangedSubview(self.eventsSection)

        self.appsRange.selectedSegment = 0
        self.appsRange.target = self
        self.appsRange.action = #selector(self.reloadApps)
        self.appsSection.add(PreferencesRow(localizedString("Period"), component: self.appsRange))
        scroll.stackView.addArrangedSubview(self.appsSection)

        self.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
        let inset = scroll.stackView.edgeInsets.left + scroll.stackView.edgeInsets.right
        for view in scroll.stackView.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: scroll.stackView.widthAnchor, constant: -inset).isActive = true
        }

        self.reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func viewWillAppear() {
        self.reload()
    }

    @objc private func changeMetric() {
        if let raw = self.metricPicker.selectedItem?.representedObject as? String, let m = HealthMetric(rawValue: raw) {
            self.metric = m
        }
        self.reload()
    }

    @objc private func reload() {
        let points = HistoryStore.shared.points(self.metric, last: self.interval)
        let events = HistoryStore.shared.events(last: self.interval)
        self.chart.set(points: points, events: events, metric: self.metric, interval: self.interval)

        if points.isEmpty {
            self.averageTile.set(localizedString("Average"), "—", color: .labelColor)
            self.peakTile.set(localizedString("Peak"), "—", color: .labelColor)
        } else {
            let avg = points.map { $0.average }.reduce(0, +) / Double(points.count)
            let peak = points.max(by: { $0.peak < $1.peak })!
            let time = DateFormatter.localizedString(from: peak.date, dateStyle: self.interval > 86400 ? .short : .none, timeStyle: .short)
            self.averageTile.set(localizedString("Average"), self.metric.format(avg), color: self.metric.severity(avg)?.textColor ?? .labelColor)
            self.peakTile.set("\(localizedString("Peak")) · \(time)", self.metric.format(peak.peak), color: self.metric.severity(peak.peak)?.textColor ?? .labelColor)
        }
        if let now = HealthMonitor.shared.value(self.metric) {
            self.nowTile.set(localizedString("Now"), self.metric.format(now), color: self.metric.severity(now)?.textColor ?? .labelColor)
        } else {
            self.nowTile.set(localizedString("Now"), "—", color: .labelColor)
        }

        // events
        self.eventRows.forEach { self.eventsSection.delete($0.identifier?.rawValue ?? "") }
        self.eventRows = []
        let recent = Array(events.suffix(8).reversed())
        if recent.isEmpty {
            let row = PreferencesRow(localizedString("No alerts in this period"), id: "event-none", component: NSView())
            self.eventsSection.add(row)
            self.eventRows.append(row)
        }
        for (i, e) in recent.enumerated() {
            let date = DateFormatter.localizedString(from: e.date, dateStyle: .short, timeStyle: .short)
            let dot = ColorBlock(color: (Severity(rawValue: e.severity) ?? .warning).color)
            let row = PreferencesRow(e.title, date, id: "event-\(i)", component: dot)
            self.eventsSection.add(row)
            self.eventRows.append(row)
        }

        self.reloadApps()
    }

    @objc private func reloadApps() {
        self.appRows.forEach { self.appsSection.delete($0.identifier?.rawValue ?? "") }
        self.appRows = []
        let days = [1, 7, 30][max(self.appsRange.selectedSegment, 0)]
        let top = AppTrafficStore.shared.top(days: days, limit: 8)
        if top.isEmpty {
            let row = PreferencesRow(localizedString("Collecting data — check back in a few minutes"), id: "app-none", component: NSView())
            self.appsSection.add(row)
            self.appRows.append(row)
            return
        }
        let maxTotal = Double(top.first?.total ?? 1)
        for (i, app) in top.enumerated() {
            let value = TextView()
            value.font = Theme.valueFont(12)
            value.stringValue = "↓ \(Units(bytes: app.download).getReadableMemory())  ↑ \(Units(bytes: app.upload).getReadableMemory())"
            let bar = UsageBar(fraction: Double(app.total) / maxTotal)
            let component = NSStackView(views: [bar, value])
            component.spacing = 10
            let row = PreferencesRow(app.app, id: "app-\(i)", component: component)
            self.appsSection.add(row)
            self.appRows.append(row)
        }
    }
}

// MARK: - Pieces

/// Summary value in a card. PreferencesSection can't be subclassed outside Kit, so it is composed.
private final class StatTile: NSStackView {
    private let titleField = TextView()
    private let valueField = TextView()
    
    init() {
        super.init(frame: .zero)
        self.titleField.font = NSFont.systemFont(ofSize: 11)
        self.titleField.textColor = .secondaryLabelColor
        self.valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        let stack = NSStackView(views: [self.titleField, self.valueField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        let card = PreferencesSection([stack])
        self.addArrangedSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func set(_ title: String, _ value: String, color: NSColor) {
        self.titleField.stringValue = title
        self.valueField.stringValue = value
        self.valueField.textColor = color
    }
}

private final class UsageBar: NSView {
    private let fraction: Double

    init(fraction: Double) {
        self.fraction = max(0.02, min(fraction, 1))
        super.init(frame: NSRect(x: 0, y: 0, width: 90, height: 6))
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: 90).isActive = true
        self.heightAnchor.constraint(equalToConstant: 6).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: self.bounds, xRadius: 3, yRadius: 3).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: self.bounds.width * self.fraction, height: self.bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}

/// Area chart of averages with a faint peak line, time axis, alert markers and a hover readout.
final class HistoryChartView: NSView {
    private var points: [HistoryPoint] = []
    private var events: [HistoryEvent] = []
    private var metric: HealthMetric = .cpuUsage
    private var interval: TimeInterval = 86400
    private var hover: CGPoint?
    private var tracking: NSTrackingArea?

    func set(points: [HistoryPoint], events: [HistoryEvent], metric: HealthMetric, interval: TimeInterval) {
        self.points = points
        self.events = events
        self.metric = metric
        self.interval = interval
        self.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { self.removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: self.bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        self.addTrackingArea(area)
        self.tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        self.hover = self.convert(event.locationInWindow, from: nil)
        self.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        self.hover = nil
        self.needsDisplay = true
    }

    private var maxValue: Double {
        switch self.metric {
        case .cpuUsage, .gpuUsage, .memoryUsage: return 1
        case .cpuTemperature, .gpuTemperature: return max(100, (self.points.map { $0.peak }.max() ?? 0) * 1.05)
        default: return max((self.points.map { $0.peak }.max() ?? 1) * 1.15, 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: 44, y: 22, width: self.bounds.width - 52, height: self.bounds.height - 34)
        let now = Date()
        let start = now.addingTimeInterval(-self.interval)
        let axis: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor.secondaryLabelColor]

        // grid + y labels
        let maxValue = self.maxValue
        for i in 0...4 {
            let y = plot.minY + plot.height * CGFloat(i) / 4
            NSColor.labelColor.withAlphaComponent(i == 0 ? 0.15 : 0.06).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 1
            line.stroke()
            let label = NSAttributedString(string: self.metric.format(maxValue * Double(i) / 4), attributes: axis)
            label.draw(at: NSPoint(x: plot.minX - label.size().width - 6, y: y - 6))
        }

        // x labels
        let ticks = self.interval > 86400 ? 7 : 6
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(self.interval > 86400 ? "EEE" : "j:mm")
        for i in 0...ticks {
            let date = start.addingTimeInterval(self.interval * Double(i) / Double(ticks))
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(ticks)
            let label = NSAttributedString(string: formatter.string(from: date), attributes: axis)
            label.draw(at: NSPoint(x: min(max(x - label.size().width / 2, plot.minX), plot.maxX - label.size().width), y: 3))
        }

        guard !self.points.isEmpty else {
            let empty = NSAttributedString(string: localizedString("History is being recorded — check back soon"), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            empty.draw(at: NSPoint(x: plot.midX - empty.size().width / 2, y: plot.midY - 6))
            return
        }

        let position: (Date, Double) -> NSPoint = { date, value in
            NSPoint(x: plot.minX + plot.width * CGFloat(date.timeIntervalSince(start) / self.interval),
                    y: plot.minY + plot.height * CGFloat(min(max(value / maxValue, 0), 1)))
        }
        let color: NSColor = .controlAccentColor

        // peak line
        let peak = NSBezierPath()
        for (i, p) in self.points.enumerated() {
            i == 0 ? peak.move(to: position(p.date, p.peak)) : peak.line(to: position(p.date, p.peak))
        }
        color.withAlphaComponent(0.35).setStroke()
        peak.lineWidth = 1
        peak.stroke()

        // average area + line
        let line = NSBezierPath()
        for (i, p) in self.points.enumerated() {
            i == 0 ? line.move(to: position(p.date, p.average)) : line.line(to: position(p.date, p.average))
        }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: position(self.points.last!.date, 0).x, y: plot.minY))
        area.line(to: NSPoint(x: position(self.points.first!.date, 0).x, y: plot.minY))
        area.close()
        NSGradient(colors: [color.withAlphaComponent(0.03), color.withAlphaComponent(0.3)])?.draw(in: area, angle: 90)
        color.setStroke()
        line.lineWidth = 1.6
        line.lineJoinStyle = .round
        line.stroke()

        // alert markers
        for e in self.events where e.date >= start {
            let x = position(e.date, 0).x
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: x - 4, y: plot.maxY + 7))
            marker.line(to: NSPoint(x: x + 4, y: plot.maxY + 7))
            marker.line(to: NSPoint(x: x, y: plot.maxY + 1))
            marker.close()
            (Severity(rawValue: e.severity) ?? .warning).color.setFill()
            marker.fill()
        }

        // hover readout
        if let hover = self.hover, plot.contains(hover) {
            let date = start.addingTimeInterval(self.interval * Double((hover.x - plot.minX) / plot.width))
            if let nearest = self.points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) {
                let p = position(nearest.date, nearest.average)
                NSColor.labelColor.withAlphaComponent(0.25).setStroke()
                let v = NSBezierPath()
                v.move(to: NSPoint(x: p.x, y: plot.minY)); v.line(to: NSPoint(x: p.x, y: plot.maxY))
                v.setLineDash([3, 3], count: 2, phase: 0)
                v.stroke()
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)).fill()

                let df = DateFormatter()
                df.setLocalizedDateFormatFromTemplate(self.interval > 86400 ? "EEE j:mm" : "j:mm")
                let text = "\(df.string(from: nearest.date))   \(self.metric.format(nearest.average))  (\(localizedString("peak")) \(self.metric.format(nearest.peak)))"
                let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
                let size = label.size()
                var box = NSRect(x: p.x + 8, y: plot.maxY - size.height - 8, width: size.width + 12, height: size.height + 6)
                if box.maxX > self.bounds.maxX { box.origin.x = p.x - box.width - 8 }
                NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                label.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3))
            }
        }
    }
}
