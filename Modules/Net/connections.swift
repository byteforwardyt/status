//
//  connections.swift
//  Status
//

import Cocoa
import Security
import Kit

// MARK: - Model

internal enum SignatureTrust: Int {
    case apple = 0
    case identified = 1
    case unknown = 2
    case unverified = 3

    var label: String {
        switch self {
        case .apple: return "Apple"
        case .identified: return "Developer ID"
        case .unknown: return "Not checked"
        case .unverified: return "Unverified"
        }
    }

    var color: NSColor {
        switch self {
        case .apple: return .secondaryLabelColor
        case .identified: return .systemGreen
        case .unknown: return .tertiaryLabelColor
        case .unverified: return .systemOrange
        }
    }
}

internal struct NetworkConnection {
    let pid: Int
    let app: String
    let path: String?
    let proto: String
    let local: String
    let remoteIP: String
    let remotePort: String
    let state: String
    let received: Int64
    let sent: Int64
    let trust: SignatureTrust
    let team: String?

    /// Remote is on the local network (private, link-local or CGNAT ranges).
    var isLocalNetwork: Bool {
        let ip = self.remoteIP.lowercased()
        if ip.hasPrefix("fe80") || ip.hasPrefix("fd") || ip.hasPrefix("fc") || ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("169.254.") {
            return true
        }
        if ip.hasPrefix("172.") {
            let second = Int(ip.split(separator: ".").dropFirst().first ?? "") ?? 0
            return (16...31).contains(second)
        }
        return false
    }
}

internal struct ConnectionsSummary {
    var connections: Int = 0
    var apps: Int = 0
    var unverifiedApps: Int = 0
}

// MARK: - Monitor

/// Lists live TCP/UDP connections for every process via `nettop` (no admin rights required)
/// and classifies each owning app by its code signature.
internal final class ConnectionsMonitor {
    static let shared = ConnectionsMonitor()

    private let queue = DispatchQueue(label: "app.status.Status.Network.Connections", qos: .utility)
    private let cacheQueue = DispatchQueue(label: "app.status.Status.Network.Connections.cache")
    private var trustCache: [String: (SignatureTrust, String?)] = [:]
    private var hostCache: [String: String] = [:]
    private var pendingHosts: Set<String> = []

    func fetch(_ completion: @escaping ([NetworkConnection]) -> Void) {
        self.queue.async {
            let list = self.read()
            DispatchQueue.main.async { completion(list) }
        }
    }

    static func summary(_ list: [NetworkConnection]) -> ConnectionsSummary {
        var apps: [Int: SignatureTrust] = [:]
        list.forEach { apps[$0.pid] = $0.trust }
        return ConnectionsSummary(
            connections: list.count,
            apps: apps.count,
            unverifiedApps: apps.values.filter({ $0 == .unverified }).count
        )
    }

    private func read() -> [NetworkConnection] {
        guard let output = process(path: "/usr/bin/nettop", arguments: ["-L", "1", "-n", "-x", "-J", "state,bytes_in,bytes_out"], timeout: 5) else {
            return []
        }

        var list: [NetworkConnection] = []
        var pid: Int = 0
        var shortName: String = ""

        for raw in output.split(separator: "\n").dropFirst() {
            let cols = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4 else { continue }
            let first = cols[0]

            if !(first.hasPrefix("tcp") || first.hasPrefix("udp")) {
                // process line: "<name>.<pid>"
                if let dot = first.lastIndex(of: "."), let p = Int(first[first.index(after: dot)...]) {
                    pid = p
                    shortName = String(first[..<dot])
                }
                continue
            }

            let state = cols[1]
            guard state != "Listen" else { continue }
            let parts = first.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let proto = parts[0]
            let ends = parts[1].components(separatedBy: "<->")
            guard ends.count == 2, let remote = Self.split(endpoint: ends[1], v6: proto.hasSuffix("6")) else { continue }
            if remote.ip == "*" || remote.ip.hasPrefix("127.") || remote.ip == "::1" { continue }

            let path = Self.executablePath(pid)
            let (trust, team) = self.trust(pid: pid, path: path)
            list.append(NetworkConnection(
                pid: pid,
                app: Self.appName(pid: pid, path: path, fallback: shortName),
                path: path,
                proto: proto.uppercased(),
                local: ends[0],
                remoteIP: remote.ip,
                remotePort: remote.port,
                state: state.isEmpty ? "—" : state,
                received: Int64(cols[2]) ?? 0,
                sent: Int64(cols[3]) ?? 0,
                trust: trust,
                team: team
            ))
        }
        return list
    }

    // "1.2.3.4:443" for v4, "fe80::1%en0.443" for v6
    private static func split(endpoint: String, v6: Bool) -> (ip: String, port: String)? {
        let separator: Character = v6 ? "." : ":"
        guard let idx = endpoint.lastIndex(of: separator) else { return nil }
        var ip = String(endpoint[..<idx])
        if let scope = ip.firstIndex(of: "%") { ip = String(ip[..<scope]) }
        return (ip, String(endpoint[endpoint.index(after: idx)...]))
    }

    static func executablePath(_ pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func appName(pid: Int, path: String?, fallback: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let name = app.localizedName {
            return name
        }
        if let path {
            // prefer the enclosing .app bundle name for helpers
            if let range = path.range(of: ".app/", options: .backwards) {
                let bundle = path[..<range.lowerBound]
                return String(bundle.split(separator: "/").last ?? Substring(fallback))
            }
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return fallback
    }

    func trust(pid: Int, path: String?) -> (SignatureTrust, String?) {
        let key = path ?? "pid:\(pid)"
        if let cached = self.cacheQueue.sync(execute: { self.trustCache[key] }) {
            return cached
        }

        // the process may have exited or be inaccessible: report "not checked" (never "unverified") and don't cache
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return (.unknown, nil)
        }

        var result: (SignatureTrust, String?) = (.unverified, nil)
        do {
            if Self.satisfies(code, "anchor apple") {
                result = (.apple, nil)
            } else if Self.satisfies(code, "anchor apple generic") {
                var team: String?
                var staticCode: SecStaticCode?
                if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
                    var info: CFDictionary?
                    if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                       let dict = info as? [String: Any] {
                        team = dict[kSecCodeInfoTeamIdentifier as String] as? String
                    }
                }
                result = (.identified, team)
            }
        }

        self.cacheQueue.sync { self.trustCache[key] = result }
        return result
    }

    private static func satisfies(_ code: SecCode, _ requirement: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    // MARK: reverse DNS

    func cachedHost(_ ip: String) -> String? {
        self.cacheQueue.sync { self.hostCache[ip] }
    }

    /// Resolves hostnames in the background; calls `completion` on main once new names arrive.
    func resolve(_ ips: [String], completion: @escaping () -> Void) {
        let todo: [String] = self.cacheQueue.sync {
            let list = Array(Set(ips)).filter { self.hostCache[$0] == nil && !self.pendingHosts.contains($0) }
            list.forEach { self.pendingHosts.insert($0) }
            return list
        }
        guard !todo.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup()
            for ip in todo.prefix(64) {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let name = Self.reverseLookup(ip) ?? ""
                    self.cacheQueue.sync {
                        self.hostCache[ip] = name
                        self.pendingHosts.remove(ip)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main, execute: completion)
        }
    }

    private static func reverseLookup(_ ip: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else {
            return nil
        }
        return String(cString: host)
    }
}

// MARK: - Window

internal final class ConnectionsWindow: NSWindow, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static var shared: ConnectionsWindow?

    private let table = NSTableView()
    private let summaryField = TextView()
    private let filter = NSSegmentedControl(labels: [localizedString("All"), localizedString("Unverified"), localizedString("Internet only")],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private var timer: Timer?
    private var all: [NetworkConnection] = []
    private var rows: [NetworkConnection] = []

    private enum Column: String, CaseIterable {
        case app = "App", trust = "Signature", host = "Remote host", address = "Address", port = "Port",
             proto = "Protocol", state = "State", received = "Received", sent = "Sent"

        var width: CGFloat {
            switch self {
            case .app: return 170
            case .trust: return 104
            case .host: return 210
            case .address: return 128
            case .port: return 48
            case .proto: return 60
            case .state: return 88
            case .received, .sent: return 82
            }
        }
    }

    static func open() {
        let window = ConnectionsWindow.shared ?? ConnectionsWindow()
        ConnectionsWindow.shared = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.startRefreshing()
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = localizedString("Network connections")
        self.titlebarAppearsTransparent = true
        self.isReleasedWhenClosed = false
        self.minSize = NSSize(width: 720, height: 360)
        self.delegate = self
        self.setFrameAutosaveName("app.status.Status.Connections.WindowFrame")
        if !self.setFrameUsingName("app.status.Status.Connections.WindowFrame") {
            self.center()
        }
        self.buildContent()
    }

    private func buildContent() {
        let root = NSVisualEffectView()
        root.material = .contentBackground
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState

        self.summaryField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        self.summaryField.translatesAutoresizingMaskIntoConstraints = false

        let hint = TextView()
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.stringValue = localizedString("Unverified apps are not signed by Apple or an identified developer. That isn't proof of anything bad, but it's where to look first.")
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.translatesAutoresizingMaskIntoConstraints = false

        self.filter.selectedSegment = 0
        self.filter.target = self
        self.filter.action = #selector(self.applyFilter)
        self.filter.translatesAutoresizingMaskIntoConstraints = false

        for column in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            c.title = localizedString(column.rawValue)
            c.width = column.width
            c.minWidth = 44
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column == .app || column == .host)
            self.table.addTableColumn(c)
        }
        self.table.style = .inset
        self.table.usesAlternatingRowBackgroundColors = true
        self.table.rowHeight = 22
        self.table.allowsColumnReordering = true
        self.table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        self.table.dataSource = self
        self.table.delegate = self
        self.table.sortDescriptors = [NSSortDescriptor(key: Column.received.rawValue, ascending: false)]

        let menu = NSMenu()
        menu.addItem(withTitle: localizedString("Copy address"), action: #selector(self.copyAddress), keyEquivalent: "")
        menu.addItem(withTitle: localizedString("Reveal app in Finder"), action: #selector(self.revealApp), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        self.table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = self.table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(self.summaryField)
        root.addSubview(hint)
        root.addSubview(self.filter)
        root.addSubview(scroll)
        self.contentView = root

        NSLayoutConstraint.activate([
            self.summaryField.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            self.summaryField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hint.topAnchor.constraint(equalTo: self.summaryField.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: self.filter.leadingAnchor, constant: -16),
            self.filter.centerYAnchor.constraint(equalTo: self.summaryField.bottomAnchor),
            self.filter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
    }

    private func startRefreshing() {
        self.refresh()
        self.timer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func windowWillClose(_ notification: Notification) {
        self.timer?.invalidate()
        self.timer = nil
    }

    func windowDidMiniaturize(_ notification: Notification) {
        self.timer?.invalidate()
        self.timer = nil
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        self.startRefreshing()
    }

    private func refresh() {
        ConnectionsMonitor.shared.fetch { [weak self] list in
            guard let self else { return }
            self.all = list
            self.applyFilter()
            ConnectionsMonitor.shared.resolve(list.filter({ !$0.isLocalNetwork }).map({ $0.remoteIP })) { [weak self] in
                self?.table.reloadData()
            }
        }
    }

    @objc private func applyFilter() {
        switch self.filter.selectedSegment {
        case 1: self.rows = self.all.filter { $0.trust == .unverified }
        case 2: self.rows = self.all.filter { !$0.isLocalNetwork }
        default: self.rows = self.all
        }
        self.sortRows()

        let s = ConnectionsMonitor.summary(self.all)
        var text = "\(s.connections) \(localizedString("connections")) · \(s.apps) \(localizedString("apps"))"
        if s.unverifiedApps > 0 {
            text += " · \(s.unverifiedApps) \(localizedString("unverified"))"
        }
        self.summaryField.stringValue = text
        self.summaryField.textColor = s.unverifiedApps > 0 ? .systemOrange : .labelColor

        let selected = self.table.selectedRow >= 0 && self.table.selectedRow < self.rows.count ? self.rows[self.table.selectedRow] : nil
        self.table.reloadData()
        if let selected, let idx = self.rows.firstIndex(where: { $0.pid == selected.pid && $0.local == selected.local && $0.remoteIP == selected.remoteIP }) {
            self.table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    private func sortRows() {
        guard let descriptor = self.table.sortDescriptors.first, let key = descriptor.key, let column = Column(rawValue: key) else { return }
        let asc = descriptor.ascending
        self.rows.sort { a, b in
            let result: Bool
            switch column {
            case .received: result = a.received < b.received
            case .sent: result = a.sent < b.sent
            case .trust: result = a.trust.rawValue < b.trust.rawValue
            case .port: result = (Int(a.remotePort) ?? 0) < (Int(b.remotePort) ?? 0)
            default: result = self.text(a, column).localizedCaseInsensitiveCompare(self.text(b, column)) == .orderedAscending
            }
            return asc ? result : !result
        }
    }

    private func text(_ c: NetworkConnection, _ column: Column) -> String {
        switch column {
        case .app: return c.app
        case .trust: return localizedString(c.trust.label)
        case .host:
            if c.isLocalNetwork { return localizedString("Local network") }
            let host = ConnectionsMonitor.shared.cachedHost(c.remoteIP)
            return (host?.isEmpty == false ? host : nil) ?? "—"
        case .address: return c.remoteIP
        case .port: return c.remotePort
        case .proto: return c.proto
        case .state: return c.state
        case .received: return Units(bytes: c.received).getReadableMemory()
        case .sent: return Units(bytes: c.sent).getReadableMemory()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { self.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue), row < self.rows.count else { return nil }
        let item = self.rows[row]

        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            var leading = field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
            if column == .app {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16)
                ])
                leading = field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)
            }
            NSLayoutConstraint.activate([
                leading,
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()

        cell.textField?.stringValue = self.text(item, column)
        switch column {
        case .app: cell.textField?.toolTip = item.path
        case .trust: cell.textField?.toolTip = item.team.map { "\(localizedString("Team ID")): \($0)" }
        case .host: cell.textField?.toolTip = cell.textField?.stringValue == "—" ? localizedString("This address has no reverse-DNS name (common for cloud and CDN servers)") : nil
        default: cell.textField?.toolTip = nil
        }
        let numeric = column == .received || column == .sent || column == .port
        cell.textField?.font = numeric ? Theme.valueFont(12) : NSFont.systemFont(ofSize: 12, weight: column == .app ? .medium : .regular)
        cell.textField?.alignment = numeric ? .right : .natural
        cell.textField?.textColor = column == .trust ? item.trust.color : (column == .host && item.isLocalNetwork ? .secondaryLabelColor : .labelColor)
        if column == .app {
            if let path = item.path {
                let bundle = path.range(of: ".app/", options: .backwards).map { String(path[..<$0.lowerBound]) + ".app" } ?? path
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: bundle)
            } else {
                cell.imageView?.image = Constants.defaultProcessIcon
            }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        self.sortRows()
        tableView.reloadData()
    }

    private var clickedItem: NetworkConnection? {
        let row = self.table.clickedRow >= 0 ? self.table.clickedRow : self.table.selectedRow
        return row >= 0 && row < self.rows.count ? self.rows[row] : nil
    }

    @objc private func copyAddress() {
        guard let item = self.clickedItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(item.remoteIP):\(item.remotePort)", forType: .string)
    }

    @objc private func revealApp() {
        guard let path = self.clickedItem?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
