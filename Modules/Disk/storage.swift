//
//  storage.swift
//  Status
//

import Cocoa
import Kit

/// Measures well-known space hogs on demand. Only folders that don't trigger macOS privacy
/// prompts are scanned (no Desktop, Documents, Downloads or other apps' containers).
internal enum StorageAnalyzer {
    struct Location {
        let name: String
        let hint: String
        let url: URL
        let size: Int64
    }

    private static let candidates: [(String, String, String)] = [
        ("User caches", "Safe to clear; apps rebuild them", "Library/Caches"),
        ("Xcode build data", "DerivedData; Xcode rebuilds it", "Library/Developer/Xcode/DerivedData"),
        ("Xcode archives", "Old app archives", "Library/Developer/Xcode/Archives"),
        ("iOS device support", "Debug symbols for old iOS versions", "Library/Developer/Xcode/iOS DeviceSupport"),
        ("Simulators", "Remove unused ones in Xcode", "Library/Developer/CoreSimulator/Devices"),
        ("Logs", "Old diagnostic logs", "Library/Logs"),
        ("npm cache", "Package manager cache", ".npm"),
        ("Gradle cache", "Build cache", ".gradle/caches"),
        ("Cargo registry", "Rust package cache", ".cargo/registry"),
        ("pip cache", "Python package cache", "Library/Caches/pip"),
        ("Homebrew cache", "Old downloads; brew cleanup", "Library/Caches/Homebrew")
    ]

    static func analyze(progress: @escaping (String) -> Void, completion: @escaping ([Location]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var result: [Location] = []
            for (name, hint, relative) in self.candidates {
                let url = home.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                DispatchQueue.main.async { progress(localizedString(name)) }
                let size = self.size(of: url)
                if size > 50_000_000 {
                    result.append(Location(name: localizedString(name), hint: localizedString(hint), url: url, size: size))
                }
            }
            // nested caches (pip, Homebrew) are also part of "User caches"; keep the more specific entries
            let sorted = result.sorted { $0.size > $1.size }
            DispatchQueue.main.async { completion(sorted) }
        }
    }

    private static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// "Storage hints" section of the Disk popup.
internal final class StorageHintsView: NSStackView {
    var sizeCallback: (() -> Void)?
    private var rows: [NSView] = []
    private let statusRow: NSView
    private let statusField: ValueField
    private var analyzing = false
    private let analyzeButton = NSButton(title: localizedString("Analyze"), target: nil, action: nil)

    init(width: CGFloat) {
        let status = popupRow(nil, title: localizedString("Find what's using space"), value: "")
        self.statusRow = status.2
        self.statusField = status.1
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        self.orientation = .vertical
        self.spacing = 0
        self.statusRow.setFrameSize(NSSize(width: width, height: 22))
        self.statusField.setFrameSize(NSSize(width: width - 140, height: 16))
        self.statusField.setFrameOrigin(NSPoint(x: 140, y: 3))

        self.addArrangedSubview(SeparatorView(
            label: localizedString("Storage hints"),
            button: PopupButton(toolTip: localizedString("Analyze"), icon: "magnifyingglass") { [weak self] in self?.analyze() }
        ))
        self.statusRow.heightAnchor.constraint(equalToConstant: 22).isActive = true
        self.addArrangedSubview(self.statusRow)
        self.statusField.stringValue = ""
        self.statusField.textColor = .secondaryLabelColor
        self.analyzeButton.bezelStyle = .rounded
        self.analyzeButton.controlSize = .small
        self.analyzeButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        self.analyzeButton.target = self
        self.analyzeButton.action = #selector(self.analyzeAction)
        self.analyzeButton.sizeToFit()
        self.analyzeButton.frame.origin = NSPoint(x: width - self.analyzeButton.frame.width, y: (22 - self.analyzeButton.frame.height) / 2)
        self.statusRow.addSubview(self.analyzeButton)
        self.setFrameSize(NSSize(width: width, height: self.contentHeight))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var contentHeight: CGFloat {
        Constants.Popup.separatorHeight + 22 + CGFloat(self.rows.count) * 22
    }

    @objc private func analyzeAction() {
        self.analyze()
    }
    
    private func analyze() {
        guard !self.analyzing else { return }
        self.analyzing = true
        self.analyzeButton.isHidden = true
        self.statusField.textColor = .secondaryLabelColor
        StorageAnalyzer.analyze(progress: { [weak self] name in
            self?.statusField.stringValue = "\(localizedString("Checking")) \(name)…"
        }, completion: { [weak self] list in
            guard let self else { return }
            self.analyzing = false
            self.rows.forEach { $0.removeFromSuperview() }
            self.rows = []
            let total = list.reduce(0) { $0 + $1.size }
            self.statusField.stringValue = list.isEmpty ? localizedString("Nothing large found") : "\(Units(bytes: total).getReadableMemory()) \(localizedString("reclaimable"))"
            self.statusField.textColor = .labelColor
            for location in list.prefix(6) {
                let row = self.row(location)
                self.addArrangedSubview(row)
                self.rows.append(row)
            }
            self.setFrameSize(NSSize(width: self.frame.width, height: self.contentHeight))
            self.sizeCallback?()
        })
    }

    private func row(_ location: StorageAnalyzer.Location) -> NSView {
        let width = self.frame.width
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let name = LabelField(frame: NSRect(x: 0, y: 3, width: width - 110, height: 16), location.name)
        name.toolTip = "\(location.hint)\n\(location.url.path)"
        let size = ValueField(frame: NSRect(x: width - 104, y: 3, width: 80, height: 16), Units(bytes: location.size).getReadableMemory())
        size.textColor = location.size > 10_000_000_000 ? Severity.warning.textColor : .labelColor

        let reveal = NSButton(image: NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
        reveal.isBordered = false
        reveal.contentTintColor = .secondaryLabelColor
        reveal.toolTip = localizedString("Show in Finder")
        reveal.frame = NSRect(x: width - 20, y: 3, width: 16, height: 16)
        let url = location.url
        reveal.target = reveal
        reveal.action = #selector(NSButton.performClickAction)
        reveal.identifier = NSUserInterfaceItemIdentifier(url.path)

        view.addSubview(name)
        view.addSubview(size)
        view.addSubview(reveal)
        return view
    }
}

private extension NSButton {
    @objc func performClickAction() {
        guard let path = self.identifier?.rawValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
