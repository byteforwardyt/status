//
//  HealthWidget.swift
//  Status
//

import SwiftUI
import WidgetKit
import Kit

public struct Health_entry: TimelineEntry {
    public var date: Date = Date()
    public var snapshot: HealthSnapshot?
}

public struct HealthProvider: TimelineProvider {
    private let userDefaults: UserDefaults? = UserDefaults(suiteName: "\(Bundle.main.object(forInfoDictionaryKey: "TeamId") as! String).app.status.Status.widgets")
    
    private static let sample = HealthSnapshot(overall: 0, items: [
        .init(title: "CPU usage", value: "18%", severity: 0),
        .init(title: "CPU temperature", value: "52°", severity: 0),
        .init(title: "Memory pressure", value: "Normal", severity: 0),
        .init(title: "Free disk space", value: "74%", severity: 0)
    ], date: Date())
    
    public func placeholder(in context: Context) -> Health_entry { Health_entry(snapshot: HealthProvider.sample) }
    
    public func getSnapshot(in context: Context, completion: @escaping (Health_entry) -> Void) {
        completion(Health_entry(snapshot: HealthProvider.sample))
    }
    
    public func getTimeline(in context: Context, completion: @escaping (Timeline<Health_entry>) -> Void) {
        // tells the app this widget is on screen so it keeps the snapshot fresh
        self.userDefaults?.set(Date().timeIntervalSince1970, forKey: HealthSnapshot.kind)
        var entry = Health_entry()
        if let raw = self.userDefaults?.data(forKey: HealthSnapshot.key) {
            entry.snapshot = try? JSONDecoder().decode(HealthSnapshot.self, from: raw)
        }
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }
}

private func color(_ severity: Int) -> Color {
    switch severity {
    case 0: return .green
    case 1: return .yellow
    case 2: return .orange
    default: return .red
    }
}

private struct HealthWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Health_entry
    
    var body: some View {
        if let snapshot = entry.snapshot {
            let titles = ["All good", "Mostly fine", "Needs attention", "Action recommended"]
            let symbols = ["checkmark.seal.fill", "checkmark.seal.fill", "exclamationmark.triangle.fill", "xmark.octagon.fill"]
            let overall = min(max(snapshot.overall, 0), 3)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: symbols[overall]).foregroundStyle(color(overall)).font(.system(size: 15, weight: .semibold))
                    Text(titles[overall]).font(.system(size: 13, weight: .bold)).lineLimit(1)
                }
                let items = Array(snapshot.items.prefix(family == .systemSmall ? 3 : 6))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: family == .systemSmall ? 1 : 3), alignment: .leading, spacing: 6) {
                    ForEach(items.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(items[i].title).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                            Text(items[i].value).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(color(items[i].severity)).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 22))
                Text("Turn on “macOS widgets” in Status settings").font(.system(size: 10)).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }
    }
}

@available(macOS 14.0, *)
public struct HealthWidget: Widget {
    public init() {}
    
    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: HealthSnapshot.kind, provider: HealthProvider()) { entry in
            HealthWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Mac Health")
        .description("Overall health and the readings that matter, color-coded.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
