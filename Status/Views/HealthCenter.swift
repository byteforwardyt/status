//
//  HealthCenter.swift
//  Status
//

import Cocoa
import Kit

extension Notification.Name {
    static let healthCenterSettingsChanged = Notification.Name("healthCenterSettingsChanged")
}

/// Menu bar health dot, its popover, and minimal mode (only the dot is shown).
final class HealthCenter: NSObject, NSPopoverDelegate {
    static let shared = HealthCenter()

    static var dotEnabled: Bool {
        get { Store.shared.bool(key: "healthDot", defaultValue: true) }
        set { Store.shared.set(key: "healthDot", value: newValue) }
    }
    static var minimalMode: Bool {
        get { Store.shared.bool(key: "minimalMode", defaultValue: false) }
        set { Store.shared.set(key: "minimalMode", value: newValue) }
    }

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var lastSeverity: Severity?

    func start() {
        self.popover.behavior = .transient
        self.popover.animates = true
        self.popover.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(self.healthChanged), name: .healthChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.settingsChanged), name: .healthCenterSettingsChanged, object: nil)
        self.applySettings()
    }

    @objc private func settingsChanged() {
        self.applySettings()
    }

    private func applySettings() {
        let showDot = HealthCenter.dotEnabled || HealthCenter.minimalMode
        if showDot && self.item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "Status_health"
            item.button?.target = self
            item.button?.action = #selector(self.toggle)
            item.button?.toolTip = localizedString("Mac health")
            self.item = item
            self.lastSeverity = nil
            self.healthChanged()
        } else if !showDot, let item = self.item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }

        // minimal mode hides module items but keeps readers (and alerts) running
        for m in modules where m.enabled {
            if HealthCenter.minimalMode {
                m.menuBar.disable()
            } else if !m.menuBar.active {
                m.menuBar.enable()
            }
        }
    }

    private let widgetDefaults = UserDefaults(suiteName: "\(Bundle.main.object(forInfoDictionaryKey: "TeamId") as? String ?? "").app.status.Status.widgets")
    
    @objc private func healthChanged() {
        // desktop widget (no-op unless "macOS widgets" is on and the widget is placed)
        SystemWidgetUpdates.shared.update(HealthSnapshot.current(), key: HealthSnapshot.key, kinds: [HealthSnapshot.kind], defaults: self.widgetDefaults)
        guard let button = self.item?.button else { return }
        let severity = HealthMonitor.shared.overall
        guard severity != self.lastSeverity else { return }
        self.lastSeverity = severity
        button.image = healthDotImage(severity)
        let names: [Severity: String] = [.good: "All good", .fair: "Mostly fine", .warning: "Needs attention", .critical: "Action recommended"]
        button.toolTip = "\(localizedString("Mac health")): \(localizedString(names[severity] ?? ""))"
    }

    @objc private func toggle() {
        guard let button = self.item?.button else { return }
        if self.popover.isShown {
            self.popover.performClose(nil)
            return
        }
        self.popover.contentViewController = HealthPopoverController()
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    var debugPopoverShown: Bool { self.popover.isShown }
    var debugPopoverWindow: NSWindow? { self.popover.contentViewController?.view.window }
    func debugToggle() { self.toggle() }
    #endif
    
    func popoverDidClose(_ notification: Notification) {
        self.popover.contentViewController = nil
    }
}

// MARK: - Popover

private final class HealthPopoverController: NSViewController {
    private let width: CGFloat = 340
    private let stack = NSStackView()
    private let insightsStack = NSStackView()
    private let metricsGrid = NSGridView()
    private let headerIcon = NSImageView()
    private let headerTitle = TextView()
    private let headerSubtitle = TextView()
    private var refreshTimer: Timer?
    private var computing = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: self.width, height: 200))

        self.stack.orientation = .vertical
        self.stack.alignment = .leading
        self.stack.spacing = 12
        self.stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(self.stack)
        NSLayoutConstraint.activate([
            self.stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            self.stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            self.stack.topAnchor.constraint(equalTo: root.topAnchor),
            self.stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: self.width)
        ])

        // header
        self.headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        self.headerTitle.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        self.headerSubtitle.font = NSFont.systemFont(ofSize: 11)
        self.headerSubtitle.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [self.headerTitle, self.headerSubtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        let header = NSStackView(views: [self.headerIcon, titles])
        header.spacing = 10
        self.stack.addArrangedSubview(header)

        // metrics
        self.metricsGrid.rowSpacing = 5
        self.metricsGrid.columnSpacing = 12
        self.stack.addArrangedSubview(self.metricsGrid)

        // insights
        self.insightsStack.orientation = .vertical
        self.insightsStack.alignment = .leading
        self.insightsStack.spacing = 8
        self.stack.addArrangedSubview(self.insightsStack)

        // footer
        let minimal = NSButton(checkboxWithTitle: localizedString("Minimal menu bar (health dot only)"), target: self, action: #selector(self.toggleMinimal))
        minimal.state = HealthCenter.minimalMode ? .on : .off
        minimal.font = NSFont.systemFont(ofSize: 11)
        let history = NSButton(title: localizedString("History…"), target: self, action: #selector(self.openHistory))
        history.bezelStyle = .rounded
        history.controlSize = .small
        let footer = NSStackView(views: [minimal, NSView(), history])
        footer.translatesAutoresizingMaskIntoConstraints = false
        self.stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalToConstant: self.width - 32).isActive = true

        self.view = root
        self.render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.render() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
    }

    private func render() {
        let monitor = HealthMonitor.shared
        let overall = monitor.overall
        let header: [Severity: (String, String, String)] = [
            .good: ("checkmark.seal.fill", "All good", "Nothing needs your attention."),
            .fair: ("checkmark.seal.fill", "Mostly fine", "A few readings are elevated but normal."),
            .warning: ("exclamationmark.triangle.fill", "Needs attention", "Something is working harder than usual."),
            .critical: ("xmark.octagon.fill", "Action recommended", "Your Mac is under strain.")
        ]
        let h = header[overall] ?? header[.good]!
        self.headerIcon.image = NSImage(systemSymbolName: h.0, accessibilityDescription: nil)
        self.headerIcon.contentTintColor = overall.color
        self.headerTitle.stringValue = localizedString(h.1)
        self.headerSubtitle.stringValue = localizedString(h.2)

        // metrics grid
        // removeRow leaves the cell views behind, so clear them explicitly
        while self.metricsGrid.numberOfRows > 0 { self.metricsGrid.removeRow(at: 0) }
        self.metricsGrid.subviews.forEach { $0.removeFromSuperview() }
        let shown: [HealthMetric] = [.cpuUsage, .cpuTemperature, .gpuUsage, .gpuTemperature, .memoryPressure, .diskFree, .batteryHealth, .latency]
        var cells: [NSView] = []
        for metric in shown {
            guard let value = monitor.value(metric, maxAge: metric == .diskFree || metric == .batteryHealth ? 3600 : 90) else { continue }
            let label = TextView()
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.stringValue = metric.title
            let field = TextView()
            field.font = Theme.valueFont(12)
            field.stringValue = metric.format(value)
            field.textColor = metric.severity(value)?.textColor ?? .labelColor
            let pair = NSStackView(views: [label, field])
            pair.orientation = .vertical
            pair.alignment = .leading
            pair.spacing = 0
            cells.append(pair)
        }
        stride(from: 0, to: cells.count, by: 3).forEach { i in
            var row = Array(cells[i..<min(i + 3, cells.count)])
            while row.count < 3 { row.append(NSView()) }
            self.metricsGrid.addRow(with: row)
        }

        // insights take a process snapshot, so compute them off the main thread
        if overall >= .warning && self.insightsStack.arrangedSubviews.isEmpty {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let label = TextView()
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.stringValue = localizedString("Looking for the cause…")
            self.insightsStack.addArrangedSubview(NSStackView(views: [spinner, label]))
            self.insightsStack.isHidden = false
        }
        guard !self.computing else { return }
        self.computing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let insights = InsightEngine.current()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.computing = false
                self.insightsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
                for insight in insights.prefix(4) {
                    let card = InsightCardView(width: self.width - 32)
                    card.set(insight)
                    self.insightsStack.addArrangedSubview(card)
                }
                self.insightsStack.isHidden = insights.isEmpty
                self.view.layoutSubtreeIfNeeded()
                self.preferredContentSize = self.view.fittingSize
            }
        }
    }

    @objc private func toggleMinimal(_ sender: NSButton) {
        HealthCenter.minimalMode = sender.state == .on
        NotificationCenter.default.post(name: .healthCenterSettingsChanged, object: nil)
    }

    @objc private func openHistory() {
        NotificationCenter.default.post(name: .toggleSettings, object: nil, userInfo: ["module": "History"])
    }
}

#if DEBUG
extension HealthCenter {
    /// Debug-only hook for the `--snapshot` UI capture mode.
    func debugShowPopover() -> NSWindow? {
        if !self.debugPopoverShown { self.debugToggle() }
        return self.debugPopoverWindow
    }
}
#endif
