//
//  AppTraffic.swift
//  Status
//

import Foundation

public struct AppTrafficTotal {
    public let app: String
    public let download: Int64
    public let upload: Int64
    public var total: Int64 { self.download + self.upload }
}

/// Network traffic per app per day. Fed once a minute by the Network module.
public final class AppTrafficStore {
    public static let shared = AppTrafficStore()

    private struct Usage: Codable {
        var download: Int64 = 0
        var upload: Int64 = 0
    }

    private let lock = NSLock()
    private let keepDays = 31
    private var days: [String: [String: Usage]] = [:] // "yyyy-MM-dd" -> app -> usage
    private var dirty = false
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Status", isDirectory: true).appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app-traffic.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: self.url), let decoded = try? JSONDecoder().decode([String: [String: Usage]].self, from: data) {
            self.days = decoded
        }
    }

    public func add(app: String, download: Int64, upload: Int64) {
        guard download > 0 || upload > 0 else { return }
        let key = self.formatter.string(from: Date())
        self.lock.lock()
        var usage = self.days[key]?[app] ?? Usage()
        usage.download += max(download, 0)
        usage.upload += max(upload, 0)
        self.days[key, default: [:]][app] = usage
        self.dirty = true
        self.lock.unlock()
    }

    /// Totals per app over the last `days` days (1 = today), largest first.
    public func top(days count: Int, limit: Int = 10) -> [AppTrafficTotal] {
        let calendar = Calendar.current
        let keys = Set((0..<max(count, 1)).compactMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }.map { self.formatter.string(from: $0) })
        self.lock.lock()
        var totals: [String: Usage] = [:]
        for (day, apps) in self.days where keys.contains(day) {
            for (app, usage) in apps {
                totals[app, default: Usage()].download += usage.download
                totals[app, default: Usage()].upload += usage.upload
            }
        }
        self.lock.unlock()
        return totals.map { AppTrafficTotal(app: $0.key, download: $0.value.download, upload: $0.value.upload) }
            .sorted { $0.total > $1.total }
            .prefix(limit)
            .map { $0 }
    }

    public func save() {
        self.lock.lock()
        guard self.dirty else { self.lock.unlock(); return }
        self.dirty = false
        if let cutoff = Calendar.current.date(byAdding: .day, value: -self.keepDays, to: Date()) {
            let cutoffKey = self.formatter.string(from: cutoff)
            self.days = self.days.filter { $0.key >= cutoffKey }
        }
        let data = try? JSONEncoder().encode(self.days)
        self.lock.unlock()
        if let data { try? data.write(to: self.url, options: .atomic) }
    }
}
