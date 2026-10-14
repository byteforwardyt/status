//
//  traffic.swift
//  Status
//

import Cocoa
import Kit

/// Once a minute: records traffic per app (for "data by app") and notices apps that go online
/// for the first time. A single `nettop` snapshot serves both.
internal final class AppTrafficMonitor {
    static let shared = AppTrafficMonitor()

    private let queue = DispatchQueue(label: "app.status.Status.Network.AppTraffic", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previous: [Int: (download: Int64, upload: Int64)] = [:]
    private var known: Set<String> = []
    // learn what's normal for the first 10 minutes of the very first run before announcing anything
    private var learningUntil: Date

    private let knownKey = "Network_knownApps"
    private let learningKey = "Network_knownApps_learningUntil"

    static var newAppAlertsEnabled: Bool {
        SmartAlerts.isEnabled && SmartAlerts.isEnabled("newApp")
    }

    private init() {
        self.known = Set(Store.shared.array(key: self.knownKey, defaultValue: []) as? [String] ?? [])
        let stored = Store.shared.int(key: self.learningKey, defaultValue: 0)
        if stored == 0 {
            self.learningUntil = Date().addingTimeInterval(600)
            Store.shared.set(key: self.learningKey, value: Int(self.learningUntil.timeIntervalSince1970))
        } else {
            self.learningUntil = Date(timeIntervalSince1970: TimeInterval(stored))
        }
    }

    func start() {
        self.queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 60, leeway: .seconds(10))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        self.queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.previous = [:]
            AppTrafficStore.shared.save()
        }
    }

    private func tick() {
        guard Store.shared.bool(key: "Network_state", defaultValue: true) else { return }
        guard let output = process(path: "/usr/bin/nettop", arguments: ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"], timeout: 10) else { return }

        var current: [Int: (download: Int64, upload: Int64)] = [:]
        var newApps: [(name: String, identity: String, pid: Int, path: String?)] = []

        for line in output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."), let pid = Int(cols[0][cols[0].index(after: dot)...]) else { continue }
            let download = Int64(cols[1]) ?? 0
            let upload = Int64(cols[2]) ?? 0
            current[pid] = (download, upload)

            // counters are cumulative per process; only count growth since the last snapshot
            let before = self.previous[pid]
            let dDown = before.map { download - $0.download } ?? 0
            let dUp = before.map { upload - $0.upload } ?? 0

            let path = ConnectionsMonitor.executablePath(pid)
            let name = ConnectionsMonitor.appName(pid: pid, path: path, fallback: String(cols[0][..<dot]))
            if dDown > 0 || dUp > 0 {
                AppTrafficStore.shared.add(app: name, download: dDown, upload: dUp)
            }

            if download + upload > 0 {
                let identity = Self.identity(path: path, name: name)
                if !self.known.contains(identity) {
                    self.known.insert(identity)
                    newApps.append((name, identity, pid, path))
                }
            }
        }
        self.previous = current

        if !newApps.isEmpty {
            Store.shared.set(key: self.knownKey, value: Array(self.known))
        }
        if Date() >= self.learningUntil {
            newApps.forEach { self.announce($0.name, pid: $0.pid, path: $0.path) }
        }
        AppTrafficStore.shared.save()
    }

    // the app bundle for helpers, otherwise the executable
    private static func identity(path: String?, name: String) -> String {
        guard let path else { return "name:\(name)" }
        if let range = path.range(of: ".app/", options: .backwards) {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return path
    }

    private func announce(_ name: String, pid: Int, path: String?) {
        let (trust, team) = ConnectionsMonitor.shared.trust(pid: pid, path: path)
        // Apple's own services come and go constantly; they're not news
        guard trust == .identified || trust == .unverified else { return }
        let severity: Severity = trust == .unverified ? .warning : .fair
        HistoryStore.shared.record(event: "\(localizedString("New app online")): \(name)", severity: severity)
        // apps from identified developers are only logged; notifications are reserved for unverified ones
        guard trust == .unverified, Self.newAppAlertsEnabled else { return }

        var body = "\(name) \(localizedString("connected to the internet for the first time")). \(localizedString("Signature")): \(localizedString(trust.label))"
        if let team { body += " (\(team))" }
        if trust == .unverified {
            body += ". \(localizedString("It isn't signed by Apple or an identified developer. If you don't recognize it, check it in Network connections."))"
        }
        SmartAlerts.notify(title: localizedString(trust == .unverified ? "Unverified app went online" : "New app online"), body: body)
    }
}
