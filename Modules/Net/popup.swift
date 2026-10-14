//
//  popup.swift
//  Status
//

import Cocoa
import Kit

// swiftlint:disable:next type_body_length
internal class Popup: PopupWrapper {
    private var uploadContainerView: NSView? = nil
    private var uploadView: NSView? = nil
    private var uploadValue: Int64 = 0
    private var uploadValueField: NSTextField? = nil
    private var uploadUnitField: NSTextField? = nil
    private var uploadStateView: ColorView? = nil
    
    private var downloadContainerView: NSView? = nil
    private var downloadView: NSView? = nil
    private var downloadValue: Int64 = 0
    private var downloadValueField: NSTextField? = nil
    private var downloadUnitField: NSTextField? = nil
    private var downloadStateView: ColorView? = nil
    
    private var downloadColorView: NSView? = nil
    private var uploadColorView: NSView? = nil
    
    private var totalUploadLabel: LabelField? = nil
    private var totalUploadField: ValueField? = nil
    private var totalDownloadLabel: LabelField? = nil
    private var totalDownloadField: ValueField? = nil
    private var statusField: StatusBadgeView? = nil
    private var connectivityField: StatusBadgeView? = nil
    private var latencyField: ValueField? = nil
    private var jitterField: ValueField? = nil
    private var packetLossField: ValueField? = nil
    private var routerLatencyField: ValueField? = nil
    private var peakDownloadField: ValueField? = nil
    private var peakUploadField: ValueField? = nil
    
    private var todayField: ValueField? = nil
    private var weekField: ValueField? = nil
    private var monthField: ValueField? = nil
    private var dailyChart: DailyUsageChart? = nil
    private var appUsageRows: [(LabelField, ValueField, NSView)] = []
    private var dailyUpdatedAt: Date = .distantPast
    
    private var signalView: NSView? = nil
    private var signalField: ValueField? = nil
    
    private var connectionsField: ValueField? = nil
    private var connectedAppsField: ValueField? = nil
    private var unverifiedAppsField: ValueField? = nil
    private var connectionsTimer: Timer? = nil
    
    private var interfaceView: NSStackView? = nil
    private var interfaceField: ValueField? = nil
    private var interfaceStatusField: StatusBadgeView? = nil
    private var macAddressField: ValueField? = nil
    private var ssidField: ValueField? = nil
    private var standardField: ValueField? = nil
    private var channelField: ValueField? = nil
    private var ssidView: NSView? = nil
    
    private var interfaceDetailsState: Bool = false
    private var standardView: NSView? = nil
    private var channelView: NSView? = nil
    private var interfaceSpeedView: NSView? = nil
    private var interfaceSpeedField: ValueField? = nil
    private var dnsServersView: NSView? = nil
    private var dnsServersField: ValueField? = nil
    
    private var addressView: NSStackView? = nil
    private var localIPField: ValueField? = nil
    private var publicIPv4Field: ValueField? = nil
    private var publicIPv6Field: ValueField? = nil
    private var publicIPv4View: NSView? = nil
    private var publicIPv6View: NSView? = nil
    private var publicIPState: Bool = true
    private var emojiCCState: Bool = true
    
    private var processesView: NSView? = nil
    private var processes: ProcessesView? = nil
    
    private var chart: NetworkChartView? = nil
    private var reverseOrderState: Bool = false
    private var chartHistory: Int = 180
    private var chartScale: Scale = .none
    private var chartFixedScale: Int = 12
    private var chartFixedScaleSize: SizeUnit = .MB
    private var chartPrefSection: PreferencesSection? = nil
    private var connectivityChart: GridChartView? = nil
    
    private var processesInitialized: Bool = false
    
    private let usageCache = PopupCache<Network_Usage>()
    private let connectivityCache = PopupCache<Network_Connectivity?>()
    
    private var lastReset: Date = Date()
    private var latency: [Double] = []
    private var jitter: [Double] = []
    
    public var locationPermissionAction: (() -> Void)?
    private var locationPermissionButton: NSButton?
    
    private var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(self.title)_base", defaultValue: "byte")) ?? .byte
    }
    private var speedUnit: String {
        networkSpeedUnit(from: Store.shared.string(key: "\(self.title)_speedUnit", defaultValue: NetworkSpeedUnitAuto)).key
    }
    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(self.title)_processes", defaultValue: 8)
    }
    private var processesHeight: CGFloat {
        (22*CGFloat(self.numberOfProcesses)) + (self.numberOfProcesses == 0 ? 0 : Constants.Popup.separatorHeight + 22)
    }
    
    private var downloadColorState: SColor = .secondBlue
    private var downloadColor: NSColor {
        var value = NSColor.systemBlue
        if let color = self.downloadColorState.additional as? NSColor {
            value = color
        }
        return value
    }
    private var uploadColorState: SColor = .secondRed
    private var uploadColor: NSColor {
        var value = NSColor.systemRed
        if let color = self.uploadColorState.additional as? NSColor {
            value = color
        }
        return value
    }
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.spacing = 0
        self.orientation = .vertical
        
        self.downloadColorState = SColor.fromString(Store.shared.string(key: "\(self.title)_downloadColor", defaultValue: self.downloadColorState.key))
        self.uploadColorState = SColor.fromString(Store.shared.string(key: "\(self.title)_uploadColor", defaultValue: self.uploadColorState.key))
        self.reverseOrderState = Store.shared.bool(key: "\(self.title)_reverseOrder", defaultValue: self.reverseOrderState)
        self.chartHistory = Store.shared.int(key: "\(self.title)_chartHistory", defaultValue: self.chartHistory)
        self.chartScale = Scale.fromString(Store.shared.string(key: "\(self.title)_chartScale", defaultValue: self.chartScale.key))
        self.chartFixedScale = Store.shared.int(key: "\(self.title)_chartFixedScale", defaultValue: self.chartFixedScale)
        self.chartFixedScaleSize = SizeUnit.fromString(Store.shared.string(key: "\(self.title)_chartFixedScaleSize", defaultValue: self.chartFixedScaleSize.key))
        self.publicIPState = Store.shared.bool(key: "\(self.title)_publicIP", defaultValue: self.publicIPState)
        self.interfaceDetailsState = Store.shared.bool(key: "\(self.title)_interfaceDetails", defaultValue: self.interfaceDetailsState)
        self.emojiCCState = Store.shared.bool(key: "\(self.title)_emojiCC", defaultValue: self.emojiCCState)
        
        self.addArrangedSubview(self.initDashboard())
        self.addArrangedSubview(self.initChart())
        self.addArrangedSubview(self.initConnectivityChart())
        self.addArrangedSubview(self.initDetails())
        self.addArrangedSubview(self.initDailyUsage())
        self.addArrangedSubview(self.initInterface())
        self.addArrangedSubview(self.initAddress())
        self.addArrangedSubview(self.initConnections())
        self.addArrangedSubview(self.initProcesses())
        
        if !self.publicIPState {
            self.addressView?.removeFromSuperview()
        }
        
        self.recalculateHeight()
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.resetTotalNetworkUsageCallback), name: .resetTotalNetworkUsage, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .resetTotalNetworkUsage, object: nil)
    }
    
    private func recalculateHeight() {
        var h: CGFloat = 0
        self.arrangedSubviews.forEach { v in
            if let v = v as? NSStackView {
                h += v.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
            } else {
                h += v.bounds.height
            }
        }
        if self.frame.size.height != h {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
    
    // MARK: - views
    
    private func initDashboard() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 90))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        
        let leftPart: NSView = NSView(frame: NSRect(x: isRTL ? view.frame.width / 2 : 0, y: 0, width: view.frame.width / 2, height: view.frame.height))
        let downloadFields = self.topValueView(leftPart, title: localizedString("Downloading"), color: self.downloadColor)
        self.downloadContainerView = leftPart
        self.downloadView = downloadFields.0
        self.downloadValueField = downloadFields.1
        self.downloadUnitField = downloadFields.2
        self.downloadStateView = downloadFields.3
        
        let rightPart: NSView = NSView(frame: NSRect(x: isRTL ? 0 : view.frame.width / 2, y: 0, width: view.frame.width / 2, height: view.frame.height))
        let uploadFields = self.topValueView(rightPart, title: localizedString("Uploading"), color: self.uploadColor)
        self.uploadContainerView = rightPart
        self.uploadView = uploadFields.0
        self.uploadValueField = uploadFields.1
        self.uploadUnitField = uploadFields.2
        self.uploadStateView = uploadFields.3
        
        view.addSubview(leftPart)
        view.addSubview(rightPart)
        
        return view
    }
    
    private func initChart() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 90 + Constants.Popup.separatorHeight))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        
        let separator = separatorView(localizedString("Usage history"), origin: NSPoint(x: 0, y: 90), width: self.frame.width)
        let container: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: separator.frame.origin.y))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = Constants.Popup.radius
        
        let chart = NetworkChartView(
            frame: NSRect(x: 0, y: 1, width: container.frame.width, height: container.frame.height - 2),
            num: self.chartHistory, reversedOrder: self.reverseOrderState, outColor: self.uploadColor, inColor: self.downloadColor,
            scale: self.chartScale,
            fixedScale: Double(self.chartFixedScaleSize.toBytes(self.chartFixedScale))
        )
        chart.setBase(self.base)
        chart.setSpeedUnit(self.speedUnit)
        container.addSubview(chart)
        self.chart = chart
        
        view.addSubview(separator)
        view.addSubview(container)
        
        return view
    }
    
    private func initConnectivityChart() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 30 + Constants.Popup.separatorHeight))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        let separator = separatorView(localizedString("Connectivity history"), origin: NSPoint(x: 0, y: 30), width: self.frame.width)
        let container: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: separator.frame.origin.y))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = 3
        
        let chart = GridChartView(frame: NSRect(x: 0, y: 1, width: container.frame.width, height: container.frame.height - 2), grid: (30, 3))
        container.addSubview(chart)
        self.connectivityChart = chart
        
        view.addSubview(separator)
        view.addSubview(container)
        
        return view
    }
    
    private func initDetails() -> NSView {
        let view = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        view.orientation = .vertical
        view.spacing = 0
        
        view.addArrangedSubview(SeparatorView(
            label: localizedString("Usage"),
            button: PopupButton(toolTip: localizedString("Reset"), icon: "arrow.clockwise") { [weak self] in
                self?.resetTotalNetworkUsage()
            }
        ))
        
        let totalUpload = popupWithColorRow(view, color: self.uploadColor, title: "\(localizedString("Total upload")):", value: "0")
        let totalDownload = popupWithColorRow(view, color: self.downloadColor, title: "\(localizedString("Total download")):", value: "0")
        
        self.uploadColorView = totalUpload.0
        self.totalUploadLabel = totalUpload.1
        self.totalUploadField = totalUpload.2
        
        self.downloadColorView = totalDownload.0
        self.totalDownloadLabel = totalDownload.1
        self.totalDownloadField = totalDownload.2
        
        self.statusField = popupBadgeRow(view, title: "\(localizedString("Status")):").1
        self.connectivityField = popupBadgeRow(view, title: "\(localizedString("Internet connection")):").1
        self.latencyField = popupRow(view, title: "\(localizedString("Latency")):", value: "0 ms").1
        self.jitterField = popupRow(view, title: "\("Jitter"):", value: "0 ms").1
        self.packetLossField = popupRow(view, title: "\(localizedString("Packet loss")):", value: localizedString("Unknown")).1
        self.routerLatencyField = popupRow(view, title: "\(localizedString("Router latency")):", value: localizedString("Unknown")).1
        self.peakDownloadField = popupRow(view, title: "\(localizedString("Peak download")):", value: "0").1
        self.peakUploadField = popupRow(view, title: "\(localizedString("Peak upload")):", value: "0").1
        
        return view
    }
    
    private func initDailyUsage() -> NSView {
        let view = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        view.orientation = .vertical
        view.spacing = 0
        
        view.addArrangedSubview(SeparatorView(label: localizedString("Data usage")))
        
        let chart = DailyUsageChart(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 64))
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 64).isActive = true
        chart.widthAnchor.constraint(equalToConstant: self.frame.width).isActive = true
        view.addArrangedSubview(chart)
        self.dailyChart = chart
        
        let spacer = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 6))
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        view.addArrangedSubview(spacer)
        
        self.todayField = popupRow(view, title: "\(localizedString("Today")):", value: "0").1
        self.weekField = popupRow(view, title: "\(localizedString("This week")):", value: "0").1
        self.monthField = popupRow(view, title: "\(localizedString("This month")):", value: "0").1
        
        view.addArrangedSubview(SeparatorView(label: localizedString("Data by app today")))
        for _ in 0..<5 {
            let row = popupRow(view, title: "—", value: "")
            row.1.font = Theme.valueFont(11.5)
            // popupRow sizes the label to its initial text; give app names room
            row.0.frame = NSRect(x: 0, y: row.0.frame.minY, width: 110, height: row.0.frame.height)
            row.1.frame = NSRect(x: 110, y: row.1.frame.minY, width: self.frame.width - 110, height: row.1.frame.height)
            self.appUsageRows.append(row)
        }
        
        return view
    }
    
    private func initConnections() -> NSView {
        let view = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        view.orientation = .vertical
        view.spacing = 0
        
        view.addArrangedSubview(SeparatorView(
            label: localizedString("Connections"),
            button: PopupButton(toolTip: localizedString("Show all connections"), icon: "list.bullet.rectangle") {
                ConnectionsWindow.open()
            }
        ))
        
        self.connectionsField = popupRow(view, title: "\(localizedString("Active connections")):", value: "—").1
        self.connectedAppsField = popupRow(view, title: "\(localizedString("Apps online")):", value: "—").1
        self.unverifiedAppsField = popupRow(view, title: "\(localizedString("Unverified apps")):", value: "—").1
        self.unverifiedAppsField?.toolTip = localizedString("Apps not signed by Apple or an identified developer that currently have network connections")
        
        return view
    }
    
    private func renderDailyUsage() {
        guard Date().timeIntervalSince(self.dailyUpdatedAt) >= 2 else { return }
        self.dailyUpdatedAt = Date()
        
        let stats = NetworkStats.shared
        let format: (DailyUsage) -> String = { u in
            "↓ \(Units(bytes: u.download).getReadableMemory())  ↑ \(Units(bytes: u.upload).getReadableMemory())"
        }
        self.todayField?.stringValue = format(stats.total(since: .day))
        self.weekField?.stringValue = format(stats.total(since: .weekOfYear))
        self.monthField?.stringValue = format(stats.total(since: .month))
        self.dailyChart?.setValues(stats.history(days: 14), download: self.downloadColor, upload: self.uploadColor)
        
        let apps = AppTrafficStore.shared.top(days: 1, limit: self.appUsageRows.count)
        for (i, row) in self.appUsageRows.enumerated() {
            if i < apps.count {
                row.0.stringValue = apps[i].app
                row.1.stringValue = "↓ \(Units(bytes: apps[i].download).getReadableMemory())  ↑ \(Units(bytes: apps[i].upload).getReadableMemory())"
            } else {
                row.0.stringValue = i == 0 && apps.isEmpty ? localizedString("Measuring…") : "—"
                row.1.stringValue = ""
            }
        }
    }
    
    private func refreshConnections() {
        ConnectionsMonitor.shared.fetch { [weak self] list in
            guard let self else { return }
            let s = ConnectionsMonitor.summary(list)
            self.connectionsField?.stringValue = "\(s.connections)"
            self.connectedAppsField?.stringValue = "\(s.apps)"
            self.unverifiedAppsField?.stringValue = "\(s.unverifiedApps)"
            self.unverifiedAppsField?.textColor = s.unverifiedApps > 0 ? .systemOrange : .labelColor
        }
    }
    
    private func initInterface() -> NSView {
        let view = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        view.orientation = .vertical
        view.spacing = 0
        
        view.addArrangedSubview(SeparatorView(
            label: localizedString("Interface"),
            button: PopupButton(toolTip: localizedString("Details"), state: interfaceDetailsState) { [weak self] in
                self?.toggleInterfaceDetails()
            }
        ))
        
        self.interfaceField = popupRow(view, title: "\(localizedString("Interface")):", value: localizedString("Unknown")).1
        self.interfaceStatusField = popupBadgeRow(view, title: "\(localizedString("Status")):").1
        self.macAddressField = popupRow(view, title: "\(localizedString("Physical address")):", value: localizedString("Unknown")).1
        self.macAddressField?.isSelectable = true
        
        let ssid = popupRow(view, title: "\(localizedString("Network")):", value: localizedString("Unknown"))
        
        let permissionButton = NSButton(title: localizedString("Open Location Settings"), target: self, action: #selector(self.requestLocationPermission))
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.font = .systemFont(ofSize: 11)
        permissionButton.isHidden = true
        
        ssid.2.addSubview(permissionButton)
        self.locationPermissionButton = permissionButton
        let signal = popupRow(view, title: "\(localizedString("Signal")):", value: localizedString("Unknown"))
        self.signalField = signal.1
        self.signalView = signal.2
        signal.2.removeFromSuperview()
        
        let standard = popupRow(view, title: "\(localizedString("Standard")):", value: localizedString("Unavailable"))
        let channel = popupRow(view, title: "\(localizedString("Channel")):", value: localizedString("Unavailable"))
        let speed = popupRow(view, title: "\(localizedString("Speed")):", value: localizedString("Unknown"))
        
        self.ssidField = ssid.1
        self.standardField = standard.1
        self.channelField = channel.1
        self.interfaceSpeedField = speed.1
        
        self.ssidView = ssid.2
        self.standardView = standard.2
        self.channelView = channel.2
        self.interfaceSpeedView = speed.2
        
        if !self.interfaceDetailsState {
            self.standardView?.removeFromSuperview()
            self.channelView?.removeFromSuperview()
            self.interfaceSpeedView?.removeFromSuperview()
        }
        
        self.interfaceView = view
        return view
    }
    
    private func initAddress() -> NSView {
        let view = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        view.orientation = .vertical
        view.spacing = 0
        
        view.addArrangedSubview(SeparatorView(
            label: localizedString("Address"),
            button: PopupButton(toolTip: localizedString("Refresh"), icon: "arrow.clockwise") { [weak self] in
                self?.refreshPublicIP()
            }
        ))
        
        self.localIPField = popupRow(view, title: "\(localizedString("Local IP")):", value: localizedString("Unknown")).1
        
        let ipV4 = popupRow(view, title: "\(localizedString("Public IP")):", value: localizedString("Unknown"))
        let ipV6 = popupRow(view, title: "\(localizedString("Public IP")):", value: localizedString("Unknown"))
        
        self.publicIPv4Field = ipV4.1
        self.publicIPv6Field = ipV6.1
        self.publicIPv4View = ipV4.2
        self.publicIPv6View = ipV6.2
        
        self.localIPField?.isSelectable = true
        self.publicIPv4Field?.isSelectable = true
        self.publicIPv6Field?.isSelectable = true
        
        if let valueView = self.publicIPv6Field {
            valueView.font = NSFont.systemFont(ofSize: 7, weight: .semibold)
            valueView.setFrameOrigin(NSPoint(x: valueView.frame.origin.x, y: -1))
        }
        
        ipV4.2.removeFromSuperview()
        ipV6.2.removeFromSuperview()
        
        self.addressView = view
        return view
    }
    
    private func initProcesses() -> NSView {
        if self.numberOfProcesses == 0 {
            let v = NSView()
            self.processesView = v
            return v
        }
        
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.processesHeight))
        let separator = separatorView(localizedString("Top processes"), origin: NSPoint(x: 0, y: self.processesHeight-Constants.Popup.separatorHeight), width: self.frame.width)
        let container: ProcessesView = ProcessesView(
            frame: NSRect(x: 0, y: 0, width: self.frame.width, height: separator.frame.origin.y),
            values: [(localizedString("Downloading"), self.downloadColor), (localizedString("Uploading"), self.uploadColor)],
            n: self.numberOfProcesses
        )
        self.processes = container
        view.addSubview(separator)
        view.addSubview(container)
        self.processesView = view
        return view
    }
    
    // MARK: - callbacks
    
    public override func appear() {
        self.replay(self.usageCache, render: self.renderUsage)
        self.replay(self.connectivityCache, render: self.renderConnectivity)
        
        self.refreshConnections()
        self.connectionsTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refreshConnections() }
        RunLoop.main.add(timer, forMode: .common)
        self.connectionsTimer = timer
    }
    
    public override func disappear() {
        self.connectionsTimer?.invalidate()
        self.connectionsTimer = nil
    }
    
    public func numberOfProcessesUpdated() {
        if self.processes?.count == self.numberOfProcesses { return }
        
        DispatchQueue.main.async(execute: {
            self.processesView?.removeFromSuperview()
            self.processesView = nil
            self.processes = nil
            self.addArrangedSubview(self.initProcesses())
            self.processesInitialized = false
            self.recalculateHeight()
        })
    }
    
    @objc private func requestLocationPermission() {
        self.locationPermissionAction?()
    }
    
    public func usageCallback(_ value: Network_Usage) {
        self.apply(value, to: self.usageCache, render: self.renderUsage)
        
        if let chart = self.chart {
            chart.setBase(self.base)
            chart.setSpeedUnit(self.speedUnit)
            chart.addValue(upload: Double(value.bandwidth.upload), download: Double(value.bandwidth.download))
        }
    }
    
    private func renderUsage(_ value: Network_Usage) {
        var resized = false
        self.uploadValue = value.bandwidth.upload
        self.downloadValue = value.bandwidth.download
        self.setUploadDownloadFields()
        
        self.totalUploadField?.stringValue = Units(bytes: value.total.upload).getReadableMemory()
        self.totalDownloadField?.stringValue = Units(bytes: value.total.download).getReadableMemory()
        self.peakDownloadField?.stringValue = Units(bytes: NetworkStats.shared.peakDownload).getReadableSpeed(base: self.base, unit: self.speedUnit)
        self.peakUploadField?.stringValue = Units(bytes: NetworkStats.shared.peakUpload).getReadableSpeed(base: self.base, unit: self.speedUnit)
        self.renderDailyUsage()
        
        let form = DateComponentsFormatter()
        form.maximumUnitCount = 2
        form.unitsStyle = .full
        form.allowedUnits = [.day, .hour, .minute]
        
        if let duration = form.string(from: self.lastReset, to: Date()) {
            self.totalUploadLabel?.toolTip = localizedString("Last reset", duration)
            self.totalDownloadLabel?.toolTip = localizedString("Last reset", duration)
        }
        
        if let interface = value.interface {
            self.interfaceField?.stringValue = "\(interface.displayName) (\(interface.BSDName)"
            if let cc = value.wifiDetails.countryCode {
                self.interfaceField?.stringValue += ", \(cc)"
            }
            self.interfaceField?.stringValue += ")"
            self.interfaceStatusField?.setStatus(interface.status)
            self.macAddressField?.stringValue = interface.address
            self.interfaceSpeedField?.stringValue = "\(Int(interface.transmitRate.rounded()))Mbps"
        } else {
            self.interfaceField?.stringValue = localizedString("Unknown")
            self.interfaceStatusField?.setStatus(nil)
            self.macAddressField?.stringValue = localizedString("Unknown")
            self.interfaceSpeedField?.stringValue = localizedString("Unknown")
        }
        
        if value.connectionType == .wifi {
            let accessRequired = value.wifiLocationAuthorization == .notDetermined || value.wifiLocationAuthorization == .denied
            if let view = self.ssidView, view.superview == nil {
                self.interfaceView?.addArrangedSubview(view)
                resized = true
            }
            if self.interfaceDetailsState, let view = self.standardView, view.superview == nil && value.wifiDetails.standard != nil {
                self.interfaceView?.addArrangedSubview(view)
                resized = true
            }
            if self.interfaceDetailsState, let view = self.channelView, view.superview == nil && value.wifiDetails.channel != nil {
                self.interfaceView?.addArrangedSubview(view)
                resized = true
            }
            
            self.ssidField?.stringValue = value.wifiDetails.ssid ?? localizedString("Unknown")
            if let v = value.wifiDetails.RSSI {
                self.ssidField?.stringValue += " (\(v))"
            }
            self.locationPermissionButton?.title = localizedString(value.wifiLocationAuthorization == .notDetermined ? "Allow access to Wi-Fi details" : "Open Location Settings")
            self.locationPermissionButton?.isHidden = !accessRequired
            self.ssidField?.isHidden = accessRequired
            if accessRequired, let button = self.locationPermissionButton, let field = self.ssidField {
                button.sizeToFit()
                button.frame.size.width = min(button.frame.width, field.frame.width)
                button.frame.origin = NSPoint(
                    x: isRTL ? field.frame.minX : field.frame.maxX - button.frame.width,
                    y: ((self.ssidView?.bounds.height ?? 22) - button.frame.height) / 2
                )
            }
            if let rssi = value.wifiDetails.RSSI, !accessRequired {
                if let view = self.signalView, view.superview == nil {
                    self.interfaceView?.addArrangedSubview(view)
                    resized = true
                }
                let severity = Severity.signal(rssi)
                let names: [Severity: String] = [.good: "Excellent", .fair: "Good", .warning: "Fair", .critical: "Poor"]
                let quality = (localizedString(names[severity] ?? "Unknown"), severity.textColor)
                var text = "\(quality.0) · \(rssi) dBm"
                if let noise = value.wifiDetails.noise {
                    text += " · SNR \(rssi - noise) dB"
                }
                self.signalField?.stringValue = text
                self.signalField?.textColor = quality.1
                self.signalField?.toolTip = localizedString("Signal strength (RSSI) and signal-to-noise ratio. Above 25 dB SNR is good.")
            } else if let view = self.signalView, view.superview != nil {
                view.removeFromSuperview()
                resized = true
            }
            self.standardField?.stringValue = value.wifiDetails.standard ?? localizedString("Unknown")
            self.channelField?.stringValue = value.wifiDetails.channel ?? localizedString("Unknown")
            
            var rssi = localizedString("Unknown")
            if let v = value.wifiDetails.RSSI {
                rssi = "\(v) dBm"
            }
            var noise = localizedString("Unknown")
            if let v = value.wifiDetails.noise {
                noise = "\(v) dBm"
            }
            
            let number = value.wifiDetails.channelNumber ?? localizedString("Unknown")
            let band = value.wifiDetails.channelBand ?? localizedString("Unknown")
            let width = value.wifiDetails.channelWidth ?? localizedString("Unknown")
            self.channelField?.toolTip = "RSSI: \(rssi)\nNoise: \(noise)\nChannel number: \(number)\nChannel band: \(band)\nChannel width: \(width)\n"
        } else {
            if self.ssidView?.superview != nil {
                self.ssidField?.stringValue = localizedString("Unavailable")
                self.ssidView?.removeFromSuperview()
                resized = true
            }
            if self.signalView?.superview != nil {
                self.signalView?.removeFromSuperview()
                resized = true
            }
            if self.standardField?.superview != nil {
                self.standardField?.stringValue = localizedString("Unavailable")
                self.standardView?.removeFromSuperview()
                resized = true
            }
            if self.channelView?.superview != nil {
                self.channelField?.stringValue = localizedString("Unavailable")
                self.channelView?.removeFromSuperview()
                resized = true
            }
        }
        
        var privateIP = localizedString("Unknown")
        if let v4 = value.laddr.v4, !v4.isEmpty {
            privateIP = v4
        } else if let v6 = value.laddr.v6, !v6.isEmpty {
            privateIP = v6
        }
        if self.localIPField?.stringValue != privateIP {
            self.localIPField?.stringValue = privateIP
        }
        
        if let view = self.publicIPv4View {
            if let addr = value.raddr.v4 {
                if view.superview == nil {
                    self.addressView?.addArrangedSubview(view)
                    resized = true
                }
                var ip = addr
                if let cc = value.raddr.countryCode, !cc.isEmpty {
                    if self.emojiCCState, let flag = countryFlag(cc) {
                        ip += " \(flag)"
                    } else {
                        ip += " (\(cc))"
                    }
                    self.publicIPv4Field?.toolTip = cc
                }
                if self.publicIPv4Field?.stringValue != ip {
                    self.publicIPv4Field?.stringValue = ip
                }
            } else if view.superview != nil {
                view.removeFromSuperview()
                resized = true
                self.publicIPv4Field?.stringValue = localizedString("Unknown")
            }
        }
        
        if let view = self.publicIPv6View {
            if let addr = value.raddr.v6 {
                if view.superview == nil {
                    self.addressView?.addArrangedSubview(view)
                    resized = true
                }
                var ip = addr
                if let cc = value.raddr.countryCode {
                    if self.emojiCCState, let flag = countryFlag(cc) {
                        ip += " \(flag)"
                    } else {
                        ip += " (\(cc))"
                    }
                    self.publicIPv6Field?.toolTip = cc
                }
                if self.publicIPv6Field?.stringValue != ip {
                    self.publicIPv6Field?.stringValue = ip
                }
            } else if view.superview != nil {
                view.removeFromSuperview()
                resized = true
                self.publicIPv6Field?.stringValue = localizedString("Unknown")
            }
        }
        
        if self.interfaceDetailsState {
            if !value.dns.isEmpty {
                let servers = value.dns.joined(separator: "\n")
                
                if self.dnsServersField == nil || value.dns.count != self.dnsServersField?.stringValue.split(separator: "\n").count {
                    if let view = self.dnsServersView {
                        view.removeFromSuperview()
                    }
                    let view = popupRow(self.interfaceView, title: "\(localizedString("DNS Server")):", value: servers, multiline: true)
                    self.dnsServersField = view.1
                    self.dnsServersView = view.2
                    self.dnsServersField?.isSelectable = true
                }
                
                if self.dnsServersField?.stringValue != servers {
                    self.dnsServersField?.stringValue = servers
                }
                
                resized = true
            } else if let view = self.dnsServersView {
                view.removeFromSuperview()
                resized = true
            }
        }
        
        self.statusField?.setStatus(value.status)
        
        if resized {
            self.recalculateHeight()
        }
        
        self.chart?.display()
    }
    
    public func connectivityCallback(_ value: Network_Connectivity?) {
        if self.latency.count >= 90 {
            self.latency.remove(at: 0)
        }
        self.latency.append(value?.latency ?? 0)
        
        if self.jitter.count >= 90 {
            self.jitter.remove(at: 0)
        }
        self.jitter.append(value?.jitter ?? 0)
        
        self.apply(value, to: self.connectivityCache, render: self.renderConnectivity)
        
        if let value, let chart = self.connectivityChart {
            chart.addValue(value.status)
        }
    }
    
    private func renderConnectivity(_ value: Network_Connectivity?) {
        var latency = localizedString("Unknown")
        var jitter = localizedString("Unknown")
        var latencyColor: NSColor = .labelColor
        var jitterColor: NSColor = .labelColor
        
        if let v = value {
            if v.status && !self.latency.isEmpty {
                let avg = self.latency.reduce(0, +) / Double(self.latency.count)
                latency = "\(avg.rounded(toPlaces: 2)) ms"
                latencyColor = Severity.latency(avg).textColor
            }
            if v.status && !self.jitter.isEmpty {
                let avg = self.jitter.reduce(0, +) / Double(self.jitter.count)
                jitter = "\(avg.rounded(toPlaces: 2)) ms"
                jitterColor = Severity.jitter(avg).textColor
            }
        }
        self.latencyField?.stringValue = latency
        self.latencyField?.textColor = latencyColor
        self.jitterField?.stringValue = jitter
        self.jitterField?.textColor = jitterColor
        
        if let loss = value?.packetLoss {
            self.packetLossField?.stringValue = "\(loss.rounded(toPlaces: 1))%"
            self.packetLossField?.textColor = Severity.packetLoss(loss).textColor
        } else {
            self.packetLossField?.stringValue = localizedString("Unknown")
            self.packetLossField?.textColor = .labelColor
        }
        if let router = value?.routerLatency {
            self.routerLatencyField?.stringValue = "\(router.rounded(toPlaces: 2)) ms"
            self.routerLatencyField?.textColor = Severity.routerLatency(router).textColor
        } else {
            self.routerLatencyField?.stringValue = localizedString("Unknown")
            self.routerLatencyField?.textColor = .labelColor
        }
        
        self.connectivityField?.setStatus(value?.status)
        self.connectivityChart?.display()
    }
    
    public func processCallback(_ list: [Network_Process]) {
        DispatchQueue.main.async(execute: {
            if !(self.window?.isVisible ?? false) && self.processesInitialized {
                return
            }
            let list = list.map{ $0 }
            if list.count != self.processes?.count { self.processes?.clear() }
            
            for i in 0..<list.count {
                let process = list[i]
                let upload = Units(bytes: Int64(process.upload)).getReadableSpeed(base: self.base, unit: self.speedUnit)
                let download = Units(bytes: Int64(process.download)).getReadableSpeed(base: self.base, unit: self.speedUnit)
                self.processes?.set(i, process, [download, upload])
            }
            
            self.processesInitialized = true
        })
    }
    
    public func resetConnectivityView() {
        self.connectivityField?.setStatus(nil)
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView? {
        let view = SettingsContainerView()
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Color of download"), component: colorSelectView(
                action: #selector(self.toggleDownloadColor),
                items: SColor.allColors,
                selected: self.downloadColorState.key
            )),
            PreferencesRow(localizedString("Color of upload"), component: colorSelectView(
                action: #selector(self.toggleUploadColor),
                items: SColor.allColors,
                selected: self.uploadColorState.key
            ))
        ]))
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Reverse order"), component: switchView(
                action: #selector(self.toggleReverseOrder),
                state: self.reverseOrderState
            ))
        ]))
        
        self.chartPrefSection = PreferencesSection([
            PreferencesRow(localizedString("Chart history"), component: selectView(
                action: #selector(self.togglechartHistory),
                items: LineChartHistory,
                selected: "\(self.chartHistory)"
            )),
            PreferencesRow(localizedString("Main chart scaling"), component: selectView(
                action: #selector(self.toggleChartScale),
                items: Scale.allCases,
                selected: self.chartScale.key
            )),
            PreferencesRow(localizedString("Scale value"), component: StepperInput(
                self.chartFixedScale, range: NSRange(location: 1, length: 1023),
                unit: self.chartFixedScaleSize.key, units: SizeUnit.allCases,
                callback: self.toggleFixedScale, unitCallback: self.toggleFixedScaleSize
            ))
        ])
        view.addArrangedSubview(self.chartPrefSection!)
        self.chartPrefSection?.setRowVisibility(2, newState: self.chartScale == .fixed)
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Public IP"), component: switchView(
                action: #selector(self.togglePublicIP),
                state: self.publicIPState
            )),
            PreferencesRow(localizedString("Show country code instead of emoji"), component: switchView(
                action: #selector(self.toggleEmojiCC),
                state: !self.emojiCCState
            ))
        ]))
        
        return view
    }
    
    @objc private func toggleUploadColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.uploadColorState = SColor.fromString(key, defaultValue: self.uploadColorState)
        Store.shared.set(key: "\(self.title)_uploadColor", value: self.uploadColorState.key)
        if let color = self.uploadColorState.additional as? NSColor {
            self.processes?.setColor(1, color)
            self.uploadColorView?.layer?.backgroundColor = color.cgColor
            self.uploadStateView?.setColor(color)
            self.chart?.setColors(out: color)
        }
    }
    @objc private func toggleDownloadColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.downloadColorState = SColor.fromString(key, defaultValue: self.downloadColorState)
        Store.shared.set(key: "\(self.title)_downloadColor", value: self.downloadColorState.key)
        if let color = self.downloadColorState.additional as? NSColor {
            self.processes?.setColor(0, color)
            self.downloadColorView?.layer?.backgroundColor = color.cgColor
            self.downloadStateView?.setColor(color)
            self.chart?.setColors(in: color)
        }
    }
    @objc private func toggleReverseOrder(_ sender: NSControl) {
        self.reverseOrderState = controlState(sender)
        self.chart?.setReverseOrder(self.reverseOrderState)
        Store.shared.set(key: "\(self.title)_reverseOrder", value: self.reverseOrderState)
        self.display()
    }
    @objc private func togglechartHistory(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.chartHistory = value
        Store.shared.set(key: "\(self.title)_chartHistory", value: value)
        self.chart?.reinit(self.chartHistory)
    }
    @objc private func toggleChartScale(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let value = Scale.allCases.first(where: { $0.key == key }) else { return }
        self.chartScale = value
        self.chart?.setScale(self.chartScale, Double(self.chartFixedScaleSize.toBytes(self.chartFixedScale)))
        self.chartPrefSection?.setRowVisibility(2, newState: self.chartScale == .fixed)
        Store.shared.set(key: "\(self.title)_chartScale", value: key)
        self.display()
    }
    @objc private func togglePublicIP(_ sender: NSControl) {
        self.publicIPState = controlState(sender)
        Store.shared.set(key: "\(self.title)_publicIP", value: self.publicIPState)
        
        DispatchQueue.main.async(execute: {
            if !self.publicIPState {
                self.addressView?.removeFromSuperview()
            } else if let view = self.addressView {
                self.insertArrangedSubview(view, at: 4)
            }
            self.recalculateHeight()
        })
    }
    @objc private func toggleFixedScale(_ newValue: Int) {
        self.chart?.setScale(self.chartScale, Double(self.chartFixedScaleSize.toBytes(newValue)))
        Store.shared.set(key: "\(self.title)_chartFixedScale", value: newValue)
    }
    private func toggleFixedScaleSize(_ newValue: KeyValue_p) {
        guard let newUnit = newValue as? SizeUnit else { return }
        self.chartFixedScaleSize = newUnit
        Store.shared.set(key: "\(self.title)_chartFixedScaleSize", value: self.chartFixedScaleSize.key)
        self.display()
    }
    @objc private func toggleInterfaceDetails() {
        self.interfaceDetailsState = !self.interfaceDetailsState
        Store.shared.set(key: "\(self.title)_interfaceDetails", value: self.interfaceDetailsState)
        
        if !self.interfaceDetailsState {
            self.standardView?.removeFromSuperview()
            self.channelView?.removeFromSuperview()
            self.interfaceSpeedView?.removeFromSuperview()
            self.dnsServersView?.removeFromSuperview()
        } else {
            if let view = self.standardView, view.superview == nil && self.standardField?.stringValue != localizedString("Unavailable") {
                self.interfaceView?.addArrangedSubview(view)
            }
            if let view = self.channelView, view.superview == nil && self.channelField?.stringValue != localizedString("Unavailable") {
                self.interfaceView?.addArrangedSubview(view)
            }
            if let view = self.interfaceSpeedView, view.superview == nil {
                self.interfaceView?.addArrangedSubview(view)
            }
            if let view = self.dnsServersView, view.superview == nil {
                self.interfaceView?.addArrangedSubview(view)
            }
        }
        
        self.recalculateHeight()
    }
    @objc private func toggleEmojiCC(_ sender: NSControl) {
        self.emojiCCState = !controlState(sender)
        Store.shared.set(key: "\(self.title)_emojiCC", value: self.emojiCCState)
    }
    
    // MARK: - helpers
    
    private func topValueView(_ view: NSView, title: String, color: NSColor) -> (NSView, NSTextField, NSTextField, ColorView) {
        let topHeight: CGFloat = 30
        let titleHeight: CGFloat = 15
        
        view.setAccessibilityElement(true)
        view.toolTip = title
        
        let valueWidth = "0".widthOfString(usingFont: .systemFont(ofSize: 26, weight: .light)) + 5
        let unitWidth = "KB/s".widthOfString(usingFont: .systemFont(ofSize: 13, weight: .light)) + 5
        let topPartWidth = valueWidth + unitWidth
        
        let topView: NSView = NSView(frame: NSRect(
            x: (view.frame.width-topPartWidth)/2,
            y: (view.frame.height - topHeight - titleHeight)/2 + titleHeight,
            width: topPartWidth,
            height: topHeight
        ))
        
        let valueField = LabelField(frame: NSRect(x: 0, y: 0, width: valueWidth, height: 30), "0")
        valueField.font = NSFont.systemFont(ofSize: 26, weight: .light)
        valueField.textColor = .textColor
        valueField.alignment = .right
        
        let unitField = LabelField(frame: NSRect(x: valueField.frame.width, y: 4, width: unitWidth, height: 15), "KB/s")
        unitField.font = NSFont.systemFont(ofSize: 13, weight: .light)
        unitField.textColor = .labelColor
        unitField.alignment = .left
        
        let titleWidth: CGFloat = title.widthOfString(usingFont: NSFont.systemFont(ofSize: 11, weight: .regular))+8
        let iconSize: CGFloat = 12
        let bottomWidth: CGFloat = titleWidth+iconSize
        let bottomView: NSView = NSView(frame: NSRect(
            x: (view.frame.width-bottomWidth)/2,
            y: topView.frame.origin.y - titleHeight - 2,
            width: bottomWidth,
            height: titleHeight
        ))
        
        let colorBlock: ColorView = ColorView(frame: NSRect(x: 0, y: 2, width: iconSize, height: iconSize), color: color, radius: 4)
        let titleField = LabelField(frame: NSRect(x: iconSize, y: 0, width: titleWidth, height: titleHeight), title)
        titleField.alignment = .center
        titleField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        
        topView.addSubview(valueField)
        topView.addSubview(unitField)
        
        bottomView.addSubview(colorBlock)
        bottomView.addSubview(titleField)
        
        view.addSubview(topView)
        view.addSubview(bottomView)
        
        return (topView, valueField, unitField, colorBlock)
    }
    
    private func setUploadDownloadFields() {
        let upload = Units(bytes: self.uploadValue).getReadableTuple(base: self.base, unit: self.speedUnit)
        let download = Units(bytes: self.downloadValue).getReadableTuple(base: self.base, unit: self.speedUnit)
        
        self.uploadContainerView?.toolTip = "\(localizedString("Uploading")): \(upload.0)\(upload.1)"
        self.downloadContainerView?.toolTip = "\(localizedString("Downloading")): \(download.0)\(download.1)"
        
        var valueWidth = "\(upload.0)".widthOfString(usingFont: .systemFont(ofSize: 26, weight: .light)) + 5
        var unitWidth = upload.1.widthOfString(usingFont: .systemFont(ofSize: 13, weight: .light)) + 5
        var topPartWidth = valueWidth + unitWidth
        
        self.uploadView?.setFrameSize(NSSize(width: topPartWidth, height: self.uploadView!.frame.height))
        self.uploadView?.setFrameOrigin(NSPoint(x: ((self.frame.width/2)-topPartWidth)/2, y: self.uploadView!.frame.origin.y))
        
        self.uploadValueField?.setFrameSize(NSSize(width: valueWidth, height: self.uploadValueField!.frame.height))
        self.uploadValueField?.stringValue = "\(upload.0)"
        self.uploadUnitField?.setFrameSize(NSSize(width: unitWidth, height: self.uploadUnitField!.frame.height))
        self.uploadUnitField?.setFrameOrigin(NSPoint(x: self.uploadValueField!.frame.width, y: self.uploadUnitField!.frame.origin.y))
        self.uploadUnitField?.stringValue = upload.1
        
        valueWidth = "\(download.0)".widthOfString(usingFont: .systemFont(ofSize: 26, weight: .light)) + 5
        unitWidth = download.1.widthOfString(usingFont: .systemFont(ofSize: 13, weight: .light)) + 5
        topPartWidth = valueWidth + unitWidth
        
        self.downloadView?.setFrameSize(NSSize(width: topPartWidth, height: self.downloadView!.frame.height))
        self.downloadView?.setFrameOrigin(NSPoint(x: ((self.frame.width/2)-topPartWidth)/2, y: self.downloadView!.frame.origin.y))
        
        self.downloadValueField?.setFrameSize(NSSize(width: valueWidth, height: self.downloadValueField!.frame.height))
        self.downloadValueField?.stringValue = "\(download.0)"
        self.downloadUnitField?.setFrameSize(NSSize(width: unitWidth, height: self.downloadUnitField!.frame.height))
        self.downloadUnitField?.setFrameOrigin(NSPoint(x: self.downloadValueField!.frame.width, y: self.downloadUnitField!.frame.origin.y))
        self.downloadUnitField?.stringValue = download.1
        
        self.uploadStateView?.setState(self.uploadValue != 0)
        self.downloadStateView?.setState(self.downloadValue != 0)
    }
    
    @objc private func refreshPublicIP() {
        NotificationCenter.default.post(name: .refreshPublicIP, object: nil, userInfo: nil)
        self.localIPField?.stringValue = localizedString("Updating...")
        self.publicIPv4Field?.stringValue = localizedString("Updating...")
        self.publicIPv6Field?.stringValue = localizedString("Updating...")
    }
    
    @objc private func resetTotalNetworkUsage() {
        NotificationCenter.default.post(name: .resetTotalNetworkUsage, object: nil, userInfo: nil)
        self.totalUploadField?.stringValue = Units(bytes: 0).getReadableMemory()
        self.totalDownloadField?.stringValue = Units(bytes: 0).getReadableMemory()
        self.lastReset = Date()
    }
    
    @objc private func resetTotalNetworkUsageCallback() {
        self.lastReset = Date()
        NetworkStats.shared.resetPeaks()
    }
}

/// Stacked download/upload bars for the last N days.
internal final class DailyUsageChart: NSView {
    private var values: [(date: Date, usage: DailyUsage)] = []
    private var downloadColor: NSColor = .systemBlue
    private var uploadColor: NSColor = .systemRed
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()
    
    func setValues(_ values: [(date: Date, usage: DailyUsage)], download: NSColor, upload: NSColor) {
        self.values = values
        self.downloadColor = download
        self.uploadColor = upload
        self.needsDisplay = true
        
        self.removeAllToolTips()
        let rects = self.barRects()
        for (i, v) in values.enumerated() where i < rects.count {
            let text = "\(self.dayFormatter.string(from: v.date))\n↓ \(Units(bytes: v.usage.download).getReadableMemory())   ↑ \(Units(bytes: v.usage.upload).getReadableMemory())"
            self.addToolTip(NSRect(x: rects[i].minX, y: 0, width: rects[i].width, height: self.bounds.height), owner: text as NSString, userData: nil)
        }
    }
    
    private func barRects() -> [NSRect] {
        guard !self.values.isEmpty else { return [] }
        let gap: CGFloat = 4
        let width = (self.bounds.width - gap * CGFloat(self.values.count - 1)) / CGFloat(self.values.count)
        return self.values.indices.map { NSRect(x: CGFloat($0) * (width + gap), y: 14, width: width, height: self.bounds.height - 14) }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rects = self.barRects()
        let maxTotal = max(self.values.map({ $0.usage.download + $0.usage.upload }).max() ?? 0, 1)
        
        for (i, v) in self.values.enumerated() where i < rects.count {
            let r = rects[i]
            let track = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            track.fill()
            
            let total = v.usage.download + v.usage.upload
            guard total > 0 else { continue }
            let h = max(2, r.height * CGFloat(Double(total) / Double(maxTotal)))
            let downH = h * CGFloat(Double(v.usage.download) / Double(total))
            
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: h), xRadius: 3, yRadius: 3).addClip()
            self.downloadColor.setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width, height: downH).fill()
            self.uploadColor.setFill()
            NSRect(x: r.minX, y: r.minY + downH, width: r.width, height: h - downH).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        if let first = self.values.first {
            NSAttributedString(string: self.dayFormatter.string(from: first.date), attributes: attrs).draw(at: NSPoint(x: 0, y: 0))
        }
        let today = NSAttributedString(string: localizedString("Today"), attributes: attrs)
        today.draw(at: NSPoint(x: self.bounds.width - today.size().width, y: 0))
    }
}
