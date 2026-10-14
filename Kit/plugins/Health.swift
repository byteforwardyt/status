//
//  Health.swift
//  Status
//

import Cocoa
import UserNotifications

// MARK: - Metrics

public enum HealthMetric: String, CaseIterable, Codable {
    case cpuUsage, cpuTemperature, gpuUsage, gpuTemperature
    case memoryUsage, memoryPressure, diskFree
    case batteryLevel, batteryHealth
    case networkDown, networkUp, latency, packetLoss

    public var title: String {
        switch self {
        case .cpuUsage: return localizedString("CPU usage")
        case .cpuTemperature: return localizedString("CPU temperature")
        case .gpuUsage: return localizedString("GPU usage")
        case .gpuTemperature: return localizedString("GPU temperature")
        case .memoryUsage: return localizedString("Memory usage")
        case .memoryPressure: return localizedString("Memory pressure")
        case .diskFree: return localizedString("Free disk space")
        case .batteryLevel: return localizedString("Battery level")
        case .batteryHealth: return localizedString("Battery health")
        case .networkDown: return localizedString("Download")
        case .networkUp: return localizedString("Upload")
        case .latency: return localizedString("Latency")
        case .packetLoss: return localizedString("Packet loss")
        }
    }

    /// Metrics shown in the history timeline.
    public static var charted: [HealthMetric] {
        [.cpuUsage, .cpuTemperature, .gpuUsage, .gpuTemperature, .memoryUsage, .networkDown, .networkUp, .latency]
    }

    public func format(_ value: Double) -> String {
        switch self {
        case .cpuUsage, .gpuUsage, .memoryUsage, .diskFree: return "\(Int((value * 100).rounded()))%"
        case .cpuTemperature, .gpuTemperature: return temperature(value)
        case .memoryPressure: return value >= 2 ? localizedString("Critical") : (value >= 1 ? localizedString("Warning") : localizedString("Normal"))
        case .batteryLevel, .batteryHealth: return "\(Int(value.rounded()))%"
        case .networkDown, .networkUp: return Units(bytes: Int64(value)).getReadableSpeed(base: .byte)
        case .latency: return "\(value.rounded(toPlaces: 1)) ms"
        case .packetLoss: return "\(value.rounded(toPlaces: 1))%"
        }
    }

    /// Health of a value; nil for metrics without a good/bad meaning (traffic).
    public func severity(_ value: Double) -> Severity? {
        switch self {
        case .cpuUsage, .gpuUsage: return Severity.usage(value)
        case .cpuTemperature, .gpuTemperature: return Severity.temperature(value)
        case .memoryPressure: return value >= 2 ? .critical : (value >= 1 ? .warning : .good)
        case .diskFree: return Severity.of(1 - value, fair: 0.8, warning: 0.9, critical: 0.95)
        case .batteryLevel: return Severity.battery(value)
        case .batteryHealth: return Severity.batteryHealth(value)
        case .latency: return Severity.latency(value)
        case .packetLoss: return Severity.packetLoss(value)
        case .memoryUsage, .networkDown, .networkUp: return nil
        }
    }
}

public extension Notification.Name {
    static let healthChanged = Notification.Name("healthChanged")
}

public struct HealthIssue {
    public let metric: HealthMetric
    public let value: Double
    public let severity: Severity
}

// MARK: - Monitor

/// Collects the latest reading of every module, records history and evaluates smart alerts.
public final class HealthMonitor {
    public static let shared = HealthMonitor()

    private let queue = DispatchQueue(label: "app.status.Status.Health")
    private var latest: [HealthMetric: (value: Double, at: Date)] = [:]
    private var lastBroadcast: Date = .distantPast
    private var broadcastPending: Bool = false

    private init() {}

    public func report(_ metric: HealthMetric, _ value: Double) {
        guard value.isFinite else { return }
        let now = Date()
        self.queue.async {
            self.latest[metric] = (value, now)
            HistoryStore.shared.add(metric, value, at: now)
            SmartAlerts.shared.evaluate(metric, value, at: now)
            self.scheduleBroadcast()
        }
    }

    /// Latest reading if it is recent enough to still be meaningful.
    public func value(_ metric: HealthMetric, maxAge: TimeInterval = 90) -> Double? {
        self.queue.sync {
            guard let entry = self.latest[metric], Date().timeIntervalSince(entry.at) <= maxAge else { return nil }
            return entry.value
        }
    }

    public var issues: [HealthIssue] {
        HealthMetric.allCases.compactMap { metric in
            // a low battery while charging is not a problem
            if metric == .batteryLevel, HealthMonitor.shared.isCharging { return nil }
            guard let value = self.value(metric), let severity = metric.severity(value), severity >= .warning else { return nil }
            return HealthIssue(metric: metric, value: value, severity: severity)
        }.sorted { $0.severity > $1.severity }
    }

    public var overall: Severity {
        let all = HealthMetric.allCases.compactMap { metric -> Severity? in
            if metric == .batteryLevel, self.isCharging { return nil }
            guard let value = self.value(metric) else { return nil }
            return metric.severity(value)
        }
        return all.max() ?? .good
    }

    private var _isCharging: Bool = false
    public var isCharging: Bool {
        get { self.queue.sync { self._isCharging } }
        set { self.queue.async { self._isCharging = newValue } }
    }

    // at most one UI refresh per second
    private func scheduleBroadcast() {
        guard !self.broadcastPending else { return }
        let delay = max(0, 1 - Date().timeIntervalSince(self.lastBroadcast))
        self.broadcastPending = true
        self.queue.asyncAfter(deadline: .now() + delay) {
            self.broadcastPending = false
            self.lastBroadcast = Date()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .healthChanged, object: nil)
            }
        }
    }
}

// MARK: - History

public struct HistoryPoint {
    public let date: Date
    public let average: Double
    public let peak: Double
}

public struct HistoryEvent: Codable {
    public let date: Date
    public let title: String
    public let severity: Int
}

/// Per-minute averages/peaks for 7 days, stored compactly on disk.
public final class HistoryStore {
    public static let shared = HistoryStore()

    private struct Bucket { var minute: Int32; var average: Float; var peak: Float }
    private struct Current { var minute: Int32; var sum: Double; var count: Int; var peak: Double }

    private let lock = NSLock()
    private let keepMinutes: Int32 = 7 * 24 * 60
    private var buckets: [HealthMetric: [Bucket]] = [:]
    private var current: [HealthMetric: Current] = [:]
    private var events: [HistoryEvent] = []
    private var lastSave: Date = Date()

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Status", isDirectory: true).appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private init() {
        self.load()
    }

    func add(_ metric: HealthMetric, _ value: Double, at date: Date) {
        let minute = Int32(date.timeIntervalSince1970 / 60)
        var shouldSave = false
        self.lock.lock()
        if var c = self.current[metric], c.minute == minute {
            c.sum += value; c.count += 1; c.peak = max(c.peak, value)
            self.current[metric] = c
        } else {
            if let c = self.current[metric], c.count > 0 {
                self.buckets[metric, default: []].append(Bucket(minute: c.minute, average: Float(c.sum / Double(c.count)), peak: Float(c.peak)))
            }
            self.current[metric] = Current(minute: minute, sum: value, count: 1, peak: value)
        }
        if date.timeIntervalSince(self.lastSave) > 300 {
            self.lastSave = date
            shouldSave = true
        }
        self.lock.unlock()
        if shouldSave { self.save() }
    }

    public func record(event title: String, severity: Severity) {
        self.lock.lock()
        self.events.append(HistoryEvent(date: Date(), title: title, severity: severity.rawValue))
        if self.events.count > 500 { self.events.removeFirst(self.events.count - 500) }
        self.lock.unlock()
        self.save()
    }

    /// Points for a metric over the last `interval`, downsampled to at most `resolution` points.
    public func points(_ metric: HealthMetric, last interval: TimeInterval, resolution: Int = 240) -> [HistoryPoint] {
        let from = Int32((Date().timeIntervalSince1970 - interval) / 60)
        self.lock.lock()
        var list = (self.buckets[metric] ?? []).filter { $0.minute >= from }
        if let c = self.current[metric], c.count > 0 {
            list.append(Bucket(minute: c.minute, average: Float(c.sum / Double(c.count)), peak: Float(c.peak)))
        }
        self.lock.unlock()
        guard !list.isEmpty else { return [] }

        let step = max(1, Int(ceil(Double(list.count) / Double(resolution))))
        return stride(from: 0, to: list.count, by: step).map { i in
            let slice = list[i..<min(i + step, list.count)]
            let avg = slice.map { Double($0.average) }.reduce(0, +) / Double(slice.count)
            let peak = slice.map { Double($0.peak) }.max() ?? avg
            return HistoryPoint(date: Date(timeIntervalSince1970: TimeInterval(slice.first!.minute) * 60), average: avg, peak: peak)
        }
    }

    public func events(last interval: TimeInterval) -> [HistoryEvent] {
        let from = Date().addingTimeInterval(-interval)
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.events.filter { $0.date >= from }
    }

    public func save() {
        self.lock.lock()
        let cutoff = Int32(Date().timeIntervalSince1970 / 60) - self.keepMinutes
        for key in self.buckets.keys {
            self.buckets[key]?.removeAll(where: { $0.minute < cutoff })
        }
        var blob = Data()
        for (metric, list) in self.buckets {
            guard let name = metric.rawValue.data(using: .utf8) else { continue }
            var nameLength = UInt8(name.count), count = UInt32(list.count)
            blob.append(Data(bytes: &nameLength, count: 1))
            blob.append(name)
            blob.append(Data(bytes: &count, count: 4))
            for var b in list {
                blob.append(Data(bytes: &b.minute, count: 4))
                blob.append(Data(bytes: &b.average, count: 4))
                blob.append(Data(bytes: &b.peak, count: 4))
            }
        }
        let events = self.events
        self.lock.unlock()

        try? blob.write(to: self.directory.appendingPathComponent("metrics.bin"), options: .atomic)
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: self.directory.appendingPathComponent("events.json"), options: .atomic)
        }
    }

    private func load() {
        if let blob = try? Data(contentsOf: self.directory.appendingPathComponent("metrics.bin")) {
            var offset = 0
            func read<T>(_ type: T.Type) -> T? {
                let size = MemoryLayout<T>.size
                guard offset + size <= blob.count else { return nil }
                defer { offset += size }
                return blob.subdata(in: offset..<offset + size).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            }
            while offset < blob.count {
                guard let nameLength = read(UInt8.self), offset + Int(nameLength) <= blob.count else { break }
                let name = String(data: blob.subdata(in: offset..<offset + Int(nameLength)), encoding: .utf8) ?? ""
                offset += Int(nameLength)
                guard let count = read(UInt32.self) else { break }
                var list: [Bucket] = []
                list.reserveCapacity(Int(count))
                for _ in 0..<count {
                    guard let m = read(Int32.self), let a = read(Float.self), let p = read(Float.self) else { break }
                    list.append(Bucket(minute: m, average: a, peak: p))
                }
                if let metric = HealthMetric(rawValue: name) {
                    self.buckets[metric] = list
                }
            }
        }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("events.json")),
           let list = try? JSONDecoder().decode([HistoryEvent].self, from: data) {
            self.events = list
        }
    }
}

// MARK: - Processes

public struct SampledProcess {
    public let pid: Int
    public let name: String
    public let cpu: Double
    public let memory: Int64
    public let path: String?
    
    public init(pid: Int, name: String, cpu: Double, memory: Int64, path: String?) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.path = path
    }
}

/// Per-process CPU and memory straight from the kernel (libproc). Unlike `ps` this stays fast
/// on a heavily loaded system and needs no extra process.
public enum ProcessSampler {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()
    
    struct Raw {
        let cpuTime: UInt64 // mach time units
        let memory: Int64
    }
    
    static func snapshot() -> [Int: Raw] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [Int: Raw] = [:]
        result.reserveCapacity(Int(filled))
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            result[Int(pid)] = Raw(cpuTime: info.pti_total_user + info.pti_total_system, memory: Int64(info.pti_resident_size))
        }
        return result
    }
    
    /// CPU % per pid between two snapshots taken `interval` seconds apart.
    static func cpu(from a: [Int: Raw], to b: [Int: Raw], interval: TimeInterval) -> [Int: Double] {
        guard interval > 0 else { return [:] }
        var out: [Int: Double] = [:]
        for (pid, now) in b {
            guard let before = a[pid], now.cpuTime >= before.cpuTime else { continue }
            let ns = Double(now.cpuTime - before.cpuTime) * self.timebase.numer / self.timebase.denom
            out[pid] = ns / (interval * 1_000_000_000) * 100
        }
        return out
    }
    
    static func describe(_ pid: Int, cpu: Double, memory: Int64) -> SampledProcess {
        let path = self.executablePath(pid)
        var name: String
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName {
            name = n
        } else {
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(Int32(pid), &buffer, 256)
            name = String(cString: buffer)
            if name.isEmpty, let path { name = URL(fileURLWithPath: path).lastPathComponent }
        }
        return SampledProcess(pid: pid, name: name, cpu: cpu, memory: memory, path: path)
    }
    
    /// Busiest processes right now (takes ~0.5 s when sorting by CPU). Call off the main thread.
    public static func top(byMemory: Bool = false, limit: Int = 5) -> [SampledProcess] {
        let first = self.snapshot()
        if byMemory {
            return first.sorted { $0.value.memory > $1.value.memory }.prefix(limit).map {
                self.describe($0.key, cpu: 0, memory: $0.value.memory)
            }
        }
        let interval: TimeInterval = 0.5
        usleep(useconds_t(interval * 1_000_000))
        let second = self.snapshot()
        let usage = self.cpu(from: first, to: second, interval: interval)
        return usage.sorted { $0.value > $1.value }.prefix(limit).map {
            self.describe($0.key, cpu: $0.value, memory: second[$0.key]?.memory ?? 0)
        }
    }
    
    /// True for processes that belong to macOS or another user; those get "Open Activity Monitor", not "Quit".
    public static func isSystemProcess(_ pid: Int, path: String?) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid != getuid() {
            return true
        }
        guard let path else { return true }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") || path.hasPrefix("/Library/Apple/")
    }
    
    public static func executablePath(_ pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Stateful sampler for readers that poll: CPU % is measured since the previous call, no sleeping.
public final class ProcessCPUSampler {
    private var previous: [Int: ProcessSampler.Raw] = [:]
    private var previousAt: Date?
    private let lock = NSLock()
    
    public init() {}
    
    public func sample(limit: Int) -> [SampledProcess] {
        let now = Date()
        let current = ProcessSampler.snapshot()
        self.lock.lock()
        let before = self.previous
        let interval = self.previousAt.map { now.timeIntervalSince($0) } ?? 0
        self.previous = current
        self.previousAt = now
        self.lock.unlock()
        guard interval > 0 else { return [] }
        return ProcessSampler.cpu(from: before, to: current, interval: interval)
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ProcessSampler.describe($0.key, cpu: $0.value, memory: current[$0.key]?.memory ?? 0) }
    }
}

// MARK: - Insights

public enum InsightAction {
    case quit(pid: Int, name: String)
    case activityMonitor
    case storage
    case openURL(URL)

    public var title: String {
        switch self {
        case .quit(_, let name): return "\(localizedString("Quit")) \(name)"
        case .activityMonitor: return localizedString("Open Activity Monitor")
        case .storage: return localizedString("Open Storage settings")
        case .openURL: return localizedString("Open")
        }
    }

    public func perform() {
        switch self {
        case .quit(let pid, _):
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                app.terminate()
            } else if let path = ProcessSampler.executablePath(pid), let range = path.range(of: ".app/", options: .backwards) {
                let bundle = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
                NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == bundle })?.terminate()
            }
        case .activityMonitor:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                NSWorkspace.shared.open(url)
            }
        case .storage:
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                NSWorkspace.shared.open(url)
            }
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        }
    }
}

public struct Insight {
    public let headline: String
    public let detail: String
    public let severity: Severity
    public let symbol: String
    public let action: InsightAction?
}

/// Turns raw readings into plain-English explanations with a suggested action.
public enum InsightEngine {
    private struct Known {
        let match: [String]
        let headline: String
        let detail: String
        let temporary: Bool
    }

    // macOS background work people commonly see at the top of the list
    private static let known: [Known] = [
        Known(match: ["mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd", "spotlightknowledged"],
              headline: "Spotlight is indexing", detail: "macOS is cataloguing files for search. It's temporary and finishes on its own, usually faster while plugged in.", temporary: true),
        Known(match: ["STExtractionService", "intelligencecontextd", "intelligenceflowd", "intelligenceplatformd", "intelligencetasksd", "knowledgeconstructiond", "generativeexperiencesd"],
              headline: "Apple Intelligence is processing", detail: "Background analysis for Apple Intelligence, common after updates or new data. It's temporary and eases off once caught up.", temporary: true),
        Known(match: ["mediaanalysisd", "photoanalysisd", "photolibraryd", "VTDecoderXPCService"],
              headline: "Photos is analyzing your library", detail: "Faces, objects and memories are being analyzed. It's temporary and runs mostly while the Mac is idle or charging.", temporary: true),
        Known(match: ["backupd", "backupd-helper"],
              headline: "Time Machine is backing up", detail: "A backup is in progress. It slows down once the backup completes.", temporary: true),
        Known(match: ["softwareupdated", "installd", "system_installd", "osinstallersetupd", "mobileassetd"],
              headline: "macOS is installing updates", detail: "An update or system asset is being downloaded or installed in the background.", temporary: true),
        Known(match: ["kernel_task"],
              headline: "macOS is cooling the CPU", detail: "kernel_task reserves CPU time to bring temperatures down. Improve airflow or close heavy apps to let it relax.", temporary: true),
        Known(match: ["WindowServer"],
              headline: "The display system is busy", detail: "WindowServer draws everything on screen. External displays, animations or a busy app drive it up.", temporary: false),
        Known(match: ["cloudd", "bird", "fileproviderd", "nsurlsessiond"],
              headline: "iCloud is syncing", detail: "Files or photos are syncing with iCloud. It settles once the transfer is done.", temporary: true),
        Known(match: ["XProtect", "XprotectService", "syspolicyd", "MRT"],
              headline: "macOS is scanning for malware", detail: "Built-in security checks are running. They're short and normal.", temporary: true)
    ]

    private static func lookup(_ name: String) -> Known? {
        self.known.first { k in k.match.contains(where: { name == $0 || name.hasPrefix($0) }) }
    }

    /// Explains high CPU load or temperature using the busiest process.
    public static func explainCPU(usage: Double?, temperature: Double?, top: [SampledProcess]) -> Insight? {
        let usageSeverity = usage.map { Severity.usage($0) } ?? .good
        let tempSeverity = temperature.map { Severity.temperature($0) } ?? .good
        let severity = max(usageSeverity, tempSeverity)
        guard severity >= .warning, let first = top.first else { return nil }

        let hot = tempSeverity >= .warning
        let prefix = hot ? "\(localizedString("Your Mac is running hot")) (\(temperature.map { Kit.temperature($0) } ?? "")). " : ""

        if let k = self.lookup(first.name) {
            return Insight(headline: localizedString(k.headline),
                           detail: prefix + localizedString(k.detail) + " (\(first.name): \(Int(first.cpu))% CPU)",
                           severity: severity, symbol: hot ? "thermometer.high" : "gearshape.2", action: .activityMonitor)
        }

        let isSystem = ProcessSampler.isSystemProcess(first.pid, path: first.path)
        let detail = prefix + String(format: localizedString("%@ is using %d%% of the CPU."), first.name, Int(first.cpu))
            + (top.count > 1 ? " \(localizedString("Next")): \(top[1].name) (\(Int(top[1].cpu))%)." : "")
        return Insight(headline: "\(first.name) \(localizedString("is working hard"))",
                       detail: detail, severity: severity, symbol: hot ? "thermometer.high" : "cpu",
                       action: isSystem ? .activityMonitor : .quit(pid: first.pid, name: first.name))
    }

    public static func explainMemory(pressure: Double?, top: [SampledProcess]) -> Insight? {
        guard let pressure, pressure >= 1, let first = top.first else { return nil }
        let size = Units(bytes: first.memory).getReadableMemory()
        let isSystem = ProcessSampler.isSystemProcess(first.pid, path: first.path)
        return Insight(headline: localizedString("Memory is running low"),
                       detail: "\(first.name) \(localizedString("is using")) \(size). \(localizedString("Quitting apps you aren't using frees memory and stops the Mac from swapping to disk."))",
                       severity: pressure >= 2 ? .critical : .warning, symbol: "memorychip",
                       action: isSystem ? .activityMonitor : .quit(pid: first.pid, name: first.name))
    }

    public static func explainDisk(free: Double) -> Insight? {
        guard let severity = HealthMetric.diskFree.severity(free), severity >= .warning else { return nil }
        return Insight(headline: localizedString("Your disk is almost full"),
                       detail: "\(Int((free * 100).rounded()))% \(localizedString("free. macOS needs free space for updates, caches and swap. Check the largest folders in the Disk popup."))",
                       severity: severity, symbol: "internaldrive", action: .storage)
    }

    /// Current insights for everything that needs attention. Samples processes, so call off the main thread.
    public static func current() -> [Insight] {
        let monitor = HealthMonitor.shared
        var list: [Insight] = []
        let usage = monitor.value(.cpuUsage)
        let temp = monitor.value(.cpuTemperature)
        if max(usage.map { Severity.usage($0) } ?? .good, temp.map { Severity.temperature($0) } ?? .good) >= .warning,
           let i = self.explainCPU(usage: usage, temperature: temp, top: ProcessSampler.top()) {
            list.append(i)
        }
        if let p = monitor.value(.memoryPressure), p >= 1, let i = self.explainMemory(pressure: p, top: ProcessSampler.top(byMemory: true)) {
            list.append(i)
        }
        if let f = monitor.value(.diskFree, maxAge: 3600), let i = self.explainDisk(free: f) {
            list.append(i)
        }
        if let h = monitor.value(.batteryHealth, maxAge: 3600), Severity.batteryHealth(h) >= .warning {
            list.append(Insight(headline: localizedString("Battery health is low"),
                                detail: "\(Int(h))% \(localizedString("of its original capacity. Consider a battery service if runtime has become short."))",
                                severity: Severity.batteryHealth(h), symbol: "battery.25", action: nil))
        }
        if let loss = monitor.value(.packetLoss), Severity.packetLoss(loss) >= .warning {
            list.append(Insight(headline: localizedString("Your connection is dropping packets"),
                                detail: "\(loss.rounded(toPlaces: 1))% \(localizedString("of checks got no reply. Check Router latency in the Network popup: if it's high too, the problem is your Wi-Fi rather than your provider."))",
                                severity: Severity.packetLoss(loss), symbol: "wifi.exclamationmark", action: nil))
        }
        return list.sorted { $0.severity > $1.severity }
    }
}

// MARK: - Smart alerts

/// Notifies about problems that persist, not momentary spikes.
public final class SmartAlerts {
    public static let shared = SmartAlerts()

    public struct Rule {
        public let id: String
        public let title: String
        public let metric: HealthMetric
        public let isProblem: (Double) -> Bool
        public let duration: TimeInterval
        public let cooldown: TimeInterval
    }

    public static let rules: [Rule] = [
        Rule(id: "cpu", title: "CPU busy for 5 minutes", metric: .cpuUsage, isProblem: { $0 >= 0.9 }, duration: 300, cooldown: 3600),
        Rule(id: "cpuHot", title: "CPU running hot", metric: .cpuTemperature, isProblem: { $0 >= 90 }, duration: 180, cooldown: 3600),
        Rule(id: "gpuHot", title: "GPU running hot", metric: .gpuTemperature, isProblem: { $0 >= 90 }, duration: 180, cooldown: 3600),
        Rule(id: "memory", title: "Memory pressure critical", metric: .memoryPressure, isProblem: { $0 >= 2 }, duration: 120, cooldown: 3600),
        Rule(id: "disk", title: "Disk almost full", metric: .diskFree, isProblem: { $0 <= 0.1 }, duration: 0, cooldown: 86400),
        Rule(id: "batteryHealth", title: "Battery health below 80%", metric: .batteryHealth, isProblem: { $0 > 0 && $0 < 80 }, duration: 0, cooldown: 7 * 86400),
        Rule(id: "packetLoss", title: "Connection dropping packets", metric: .packetLoss, isProblem: { $0 >= 5 }, duration: 120, cooldown: 3600)
    ]

    public static var isEnabled: Bool { Store.shared.bool(key: "SmartAlerts", defaultValue: true) }
    public static func isEnabled(_ id: String) -> Bool { Store.shared.bool(key: "SmartAlerts_\(id)", defaultValue: true) }

    private var since: [String: Date] = [:]
    private var lastFired: [String: Date] = [:]

    // called on the HealthMonitor queue
    func evaluate(_ metric: HealthMetric, _ value: Double, at now: Date) {
        for rule in SmartAlerts.rules where rule.metric == metric {
            guard rule.isProblem(value) else {
                self.since[rule.id] = nil
                continue
            }
            let start = self.since[rule.id] ?? now
            self.since[rule.id] = start
            guard now.timeIntervalSince(start) >= rule.duration else { continue }
            if let last = self.lastFired[rule.id] ?? self.storedLastFired(rule.id), now.timeIntervalSince(last) < rule.cooldown { continue }
            self.lastFired[rule.id] = now
            Store.shared.set(key: "SmartAlerts_\(rule.id)_last", value: Int(now.timeIntervalSince1970))
            self.fire(rule, value: value)
        }
    }

    private func storedLastFired(_ id: String) -> Date? {
        let ts = Store.shared.int(key: "SmartAlerts_\(id)_last", defaultValue: 0)
        return ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : nil
    }

    private func fire(_ rule: Rule, value: Double) {
        let severity = rule.metric.severity(value) ?? .warning
        HistoryStore.shared.record(event: localizedString(rule.title), severity: severity)
        guard SmartAlerts.isEnabled, SmartAlerts.isEnabled(rule.id) else { return }

        DispatchQueue.global(qos: .utility).async {
            var subtitle = "\(rule.metric.title): \(rule.metric.format(value))"
            if rule.metric == .cpuUsage || rule.metric == .cpuTemperature,
               let insight = InsightEngine.explainCPU(usage: HealthMonitor.shared.value(.cpuUsage) ?? 1, temperature: HealthMonitor.shared.value(.cpuTemperature), top: ProcessSampler.top()) {
                subtitle = "\(insight.headline). \(insight.detail)"
            } else if rule.metric == .memoryPressure, let insight = InsightEngine.explainMemory(pressure: value, top: ProcessSampler.top(byMemory: true)) {
                subtitle = insight.detail
            }
            SmartAlerts.notify(title: localizedString(rule.title), body: subtitle)
        }
    }

    /// Posts a user notification, asking for permission on first use.
    public static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let send = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                center.add(UNNotificationRequest(identifier: "Status_alert_\(UUID().uuidString)", content: content, trigger: nil))
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional: send()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
            default: break
            }
        }
    }
}

// MARK: - Desktop widget snapshot

/// What the "Mac Health" desktop widget shows; written to the shared widget defaults.
public struct HealthSnapshot: Codable {
    public struct Item: Codable {
        public let title: String
        public let value: String
        public let severity: Int
        
        public init(title: String, value: String, severity: Int) {
            self.title = title
            self.value = value
            self.severity = severity
        }
    }
    public let overall: Int
    public let items: [Item]
    public let date: Date
    
    public init(overall: Int, items: [Item], date: Date) {
        self.overall = overall
        self.items = items
        self.date = date
    }
    
    public static let key = "Health@Snapshot"
    public static let kind = "HealthWidget"
    
    public static func current() -> HealthSnapshot {
        let monitor = HealthMonitor.shared
        let metrics: [HealthMetric] = [.cpuUsage, .cpuTemperature, .memoryPressure, .diskFree, .gpuUsage, .batteryHealth]
        let items: [Item] = metrics.compactMap { m in
            guard let v = monitor.value(m, maxAge: m == .diskFree || m == .batteryHealth ? 3600 : 120) else { return nil }
            return Item(title: m.title, value: m.format(v), severity: (m.severity(v) ?? .good).rawValue)
        }
        return HealthSnapshot(overall: monitor.overall.rawValue, items: items, date: Date())
    }
}
