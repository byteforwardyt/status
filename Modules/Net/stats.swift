//
//  stats.swift
//  Status
//

import Foundation
import Kit
import SystemConfiguration

public struct DailyUsage: Codable {
    public var download: Int64 = 0
    public var upload: Int64 = 0
}

/// Accumulates per-day traffic and session peak speeds. Fed by the usage reader every tick.
internal final class NetworkStats {
    static let shared = NetworkStats()

    private let queue = DispatchQueue(label: "app.status.Status.Network.Stats")
    private let storeKey = "Network_dailyUsage"
    private let keepDays = 62
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var days: [String: DailyUsage] = [:]
    private var lastPersist: Date = Date()
    private var dirty: Bool = false
    private var _peakDownload: Int64 = 0
    private var _peakUpload: Int64 = 0

    private init() {
        if let data = Store.shared.data(key: self.storeKey),
           let decoded = try? JSONDecoder().decode([String: DailyUsage].self, from: data) {
            self.days = decoded
        }
    }

    var peakDownload: Int64 { self.queue.sync { self._peakDownload } }
    var peakUpload: Int64 { self.queue.sync { self._peakUpload } }

    func add(download: Int64, upload: Int64) {
        guard download > 0 || upload > 0 else { return }
        let key = self.formatter.string(from: Date())
        let shouldPersist: Bool = self.queue.sync {
            var day = self.days[key] ?? DailyUsage()
            day.download += download
            day.upload += upload
            self.days[key] = day
            self._peakDownload = max(self._peakDownload, download)
            self._peakUpload = max(self._peakUpload, upload)
            self.dirty = true
            return Date().timeIntervalSince(self.lastPersist) > 60
        }
        if shouldPersist {
            self.persist()
        }
    }

    func resetPeaks() {
        self.queue.sync {
            self._peakDownload = 0
            self._peakUpload = 0
        }
    }

    func persist() {
        let data: Data? = self.queue.sync {
            guard self.dirty else { return nil }
            self.dirty = false
            self.lastPersist = Date()
            if let cutoff = Calendar.current.date(byAdding: .day, value: -self.keepDays, to: Date()) {
                let cutoffKey = self.formatter.string(from: cutoff)
                self.days = self.days.filter { $0.key >= cutoffKey }
            }
            return try? JSONEncoder().encode(self.days)
        }
        if let data {
            Store.shared.set(key: self.storeKey, value: data)
        }
    }

    /// Usage for the last `count` days, oldest first, zero-filled.
    func history(days count: Int) -> [(date: Date, usage: DailyUsage)] {
        let snapshot = self.queue.sync { self.days }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (date, snapshot[self.formatter.string(from: date)] ?? DailyUsage())
        }
    }

    /// Total since the start of the given calendar component (day, week or month) that contains today.
    func total(since component: Calendar.Component) -> DailyUsage {
        let snapshot = self.queue.sync { self.days }
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: component, for: Date()) else { return DailyUsage() }
        let startKey = self.formatter.string(from: interval.start)
        return snapshot.filter { $0.key >= startKey }.values.reduce(into: DailyUsage()) {
            $0.download += $1.download
            $0.upload += $1.upload
        }
    }
}

/// Pings the default gateway with an unprivileged ICMP datagram socket, so local (Wi‑Fi/router)
/// latency can be told apart from internet latency.
internal final class GatewayPinger {
    private let queue = DispatchQueue(label: "app.status.Status.Network.Gateway", qos: .utility)
    private let stateQueue = DispatchQueue(label: "app.status.Status.Network.Gateway.state")
    private var _latency: Double?
    private var _router: String?
    private var routerResolvedAt: Date = .distantPast
    private var busy: Bool = false
    private var sequence: UInt16 = 0
    private let identifier = UInt16.random(in: 1..<UInt16.max)
    
    var latency: Double? { self.stateQueue.sync { self._latency } }
    var router: String? { self.stateQueue.sync { self._router } }
    
    func ping() {
        let start: Bool = self.stateQueue.sync {
            if self.busy { return false }
            self.busy = true
            return true
        }
        guard start else { return }
        
        self.queue.async {
            defer { self.stateQueue.sync { self.busy = false } }
            if Date().timeIntervalSince(self.routerResolvedAt) > 30 {
                let router = Self.defaultRouter()
                self.routerResolvedAt = Date()
                self.stateQueue.sync { self._router = router }
            }
            guard let router = self.router else {
                self.stateQueue.sync { self._latency = nil }
                return
            }
            let result = self.echo(router)
            self.stateQueue.sync { self._latency = result }
        }
    }
    
    private static func defaultRouter() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Status" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return dict["Router"] as? String
    }
    
    private func echo(_ host: String, timeout: TimeInterval = 1) -> Double? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        
        self.sequence &+= 1
        let seq = self.sequence
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8 // echo request
        packet[4] = UInt8(self.identifier >> 8); packet[5] = UInt8(self.identifier & 0xff)
        packet[6] = UInt8(seq >> 8); packet[7] = UInt8(seq & 0xff)
        var sum: UInt32 = 0
        for i in stride(from: 0, to: packet.count, by: 2) { sum += UInt32(packet[i]) << 8 | UInt32(packet[i+1]) }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        let checksum = ~UInt16(sum)
        packet[2] = UInt8(checksum >> 8); packet[3] = UInt8(checksum & 0xff)
        
        let started = DispatchTime.now()
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return nil }
        
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            // datagram ICMP sockets deliver the IP header first
            let ipLength = Int(buffer[0] & 0x0f) * 4
            guard n >= ipLength + 8 else { continue }
            let type = buffer[ipLength]
            let rseq = UInt16(buffer[ipLength + 6]) << 8 | UInt16(buffer[ipLength + 7])
            if type == 0 && rseq == seq {
                return Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            }
            if Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000 > timeout { return nil }
        }
    }
}
