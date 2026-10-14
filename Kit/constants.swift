//
//  constants.swift
//  Status
//

import Cocoa

public struct Popup_c_s {
    public let width: CGFloat = 264
    public let height: CGFloat = 300
    public let margins: CGFloat = 10
    public let spacing: CGFloat = 2
    public let headerHeight: CGFloat = 44
    public let separatorHeight: CGFloat = 30
    public let radius: CGFloat = 8
    public let windowRadius: CGFloat = 16
    public let processHeight: CGFloat = 22
}

public struct Settings_c_s {
    public let width: CGFloat = 540
    public let height: CGFloat = 480
    public let margin: CGFloat = 10
}

public struct Widget_c_s {
    public let width: CGFloat = 32
    public var height: CGFloat {
        get {
            let systemHeight = NSApplication.shared.mainMenu?.menuBarHeight
            return (systemHeight == 0 ? 22 : systemHeight) ?? 22
        }
    }
    public var margin: CGPoint {
        get { CGPoint(x: 0, y: 2) }
    }
    public let spacing: CGFloat = 2
}

/// Green / Yellow / Orange / Red health levels used to color-code values across the app.
public enum Severity: Int, Comparable {
    case good, fair, warning, critical
    
    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    
    public var color: NSColor {
        switch self {
        case .good: return .systemGreen
        case .fair: return .systemYellow
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
    
    /// Color for text in popups; follows the "Color-coded values" setting.
    public var textColor: NSColor {
        Severity.isEnabled ? self.color : .labelColor
    }
    
    public static var isEnabled: Bool {
        Store.shared.bool(key: "colorCoding", defaultValue: true)
    }
    
    /// Higher value is worse.
    public static func of(_ value: Double, fair: Double, warning: Double, critical: Double) -> Severity {
        if value >= critical { return .critical }
        if value >= warning { return .warning }
        if value >= fair { return .fair }
        return .good
    }
    
    // Thresholds per metric
    public static func usage(_ fraction: Double) -> Severity { .of(fraction, fair: 0.4, warning: 0.6, critical: 0.8) }
    public static func temperature(_ celsius: Double) -> Severity { .of(celsius, fair: 60, warning: 75, critical: 90) }
    public static func latency(_ ms: Double) -> Severity { .of(ms, fair: 30, warning: 80, critical: 150) }
    public static func jitter(_ ms: Double) -> Severity { .of(ms, fair: 10, warning: 30, critical: 60) }
    public static func routerLatency(_ ms: Double) -> Severity { .of(ms, fair: 5, warning: 20, critical: 50) }
    public static func packetLoss(_ percent: Double) -> Severity { .of(percent, fair: 0.1, warning: 1, critical: 5) }
    public static func signal(_ rssi: Int) -> Severity { .of(Double(-rssi), fair: 55, warning: 65, critical: 75) }
    /// Lower value is worse.
    public static func battery(_ percent: Double) -> Severity { .of(100 - percent, fair: 60, warning: 80, critical: 90) }
    public static func batteryHealth(_ percent: Double) -> Severity { .of(100 - percent, fair: 15, warning: 25, critical: 40) }
}

/// Shared visual language for Status: typography, radii and module tints.
public struct Theme {
    public static let cardRadius: CGFloat = 12
    public static let rowRadius: CGFloat = 8
    
    public static func labelFont(_ size: CGFloat = 12) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
    }
    public static func valueFont(_ size: CGFloat = 12.5) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }
    public static let sectionFont: NSFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    
    public static var cardBackground: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.055)
                : NSColor.black.withAlphaComponent(0.035)
        }
    }
    public static var cardBorder: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.06)
        }
    }
    public static var hairline: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.08)
        }
    }
    
    /// Tile color used for a module's icon in the settings sidebar and popup headers.
    public static func tint(for name: String) -> NSColor {
        switch name {
        case "Dashboard": return .systemIndigo
        case "History": return .systemYellow
        case "CPU": return .systemBlue
        case "GPU": return .systemPurple
        case "RAM": return .systemGreen
        case "Disk": return .systemOrange
        case "Sensors": return .systemRed
        case "Network": return .systemTeal
        case "Battery": return .systemMint
        case "Bluetooth": return .systemCyan
        case "Clock": return .systemPink
        case "Combined modules": return .systemBrown
        default: return .systemGray
        }
    }
}

/// A rounded, colored square holding a white SF Symbol, in the style of System Settings.
public class IconTile: NSView {
    private let imageView = NSImageView()
    private var tint: NSColor
    
    public init(symbol: NSImage?, tint: NSColor, size: CGFloat = 22) {
        self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        self.wantsLayer = true
        self.layer?.cornerRadius = size * 0.27
        self.layer?.cornerCurve = .continuous
        
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
        self.imageView.image = symbol?.withSymbolConfiguration(config)
        self.imageView.contentTintColor = .white
        self.imageView.imageScaling = .scaleNone
        self.imageView.frame = self.bounds
        self.imageView.autoresizingMask = [.width, .height]
        self.addSubview(self.imageView)
        
        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: size),
            self.heightAnchor.constraint(equalToConstant: size)
        ])
        self.updateLayer()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override var wantsUpdateLayer: Bool { true }
    
    public override func updateLayer() {
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let top = self.tint.blended(withFraction: 0.18, of: .white) ?? self.tint
            let gradient = CAGradientLayer()
            gradient.colors = [top.cgColor, self.tint.cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.frame = self.bounds
            gradient.cornerRadius = self.layer?.cornerRadius ?? 0
            gradient.cornerCurve = .continuous
            self.layer?.sublayers?.filter({ $0 is CAGradientLayer }).forEach({ $0.removeFromSuperlayer() })
            self.layer?.insertSublayer(gradient, at: 0)
        }
    }
}

public struct Constants {
    public static let Popup: Popup_c_s = Popup_c_s()
    public static let Settings: Settings_c_s = Settings_c_s()
    public static let Widget: Widget_c_s = Widget_c_s()
    
    public static let defaultProcessIcon = NSWorkspace.shared.icon(forFile: "/bin/bash")
}

public enum ModuleType: Int {
    case CPU
    case RAM
    case GPU
    case disk
    case sensors
    case network
    case battery
    case bluetooth
    case clock
    
    case combined
    
    public var stringValue: String {
        switch self {
        case .CPU: return "CPU"
        case .RAM: return "RAM"
        case .GPU: return "GPU"
        case .disk: return "Disk"
        case .sensors: return "Sensors"
        case .network: return "Network"
        case .battery: return "Battery"
        case .bluetooth: return "Bluetooth"
        case .clock: return "Clock"
        case .combined: return ""
        }
    }
    
    public var activityMonitorTab: Int? {
        switch self {
        case .CPU: return 0
        case .RAM: return 1
        case .disk: return 3
        case .network: return 4
        case .battery: return 2
        default: return nil
        }
    }
}
