//
//  HealthViews.swift
//  Status
//

import Cocoa

/// Rounded, severity-tinted card explaining a problem, with an optional action button.
public final class InsightCardView: NSView {
    private let iconView = NSImageView()
    private let headlineField = NSTextField(wrappingLabelWithString: "")
    private let detailField = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var action: InsightAction?
    private var severity: Severity = .warning

    public init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        self.wantsLayer = true
        self.layer?.cornerRadius = 10
        self.layer?.cornerCurve = .continuous
        self.layer?.borderWidth = 1

        self.iconView.translatesAutoresizingMaskIntoConstraints = false
        self.iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)

        self.headlineField.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        self.headlineField.textColor = .labelColor
        self.detailField.font = NSFont.systemFont(ofSize: 11)
        self.detailField.textColor = .secondaryLabelColor
        [self.headlineField, self.detailField].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isSelectable = false
            // a little narrower than the real column so the measured height never comes up a line short
            $0.preferredMaxLayoutWidth = width - 58
        }

        self.actionButton.bezelStyle = .rounded
        self.actionButton.controlSize = .small
        self.actionButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        self.actionButton.target = self
        self.actionButton.action = #selector(self.performAction)
        self.actionButton.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [self.headlineField, self.detailField, self.actionButton])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setCustomSpacing(7, after: self.detailField)
        text.translatesAutoresizingMaskIntoConstraints = false

        self.addSubview(self.iconView)
        self.addSubview(text)

        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: width),
            self.iconView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12),
            self.iconView.topAnchor.constraint(equalTo: self.topAnchor, constant: 11),
            self.iconView.widthAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: self.iconView.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: self.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ insight: Insight) {
        self.severity = insight.severity
        self.iconView.image = NSImage(systemSymbolName: insight.symbol, accessibilityDescription: nil)
        self.iconView.contentTintColor = insight.severity.color
        self.headlineField.stringValue = insight.headline
        self.detailField.stringValue = insight.detail
        self.action = insight.action
        self.actionButton.isHidden = insight.action == nil
        self.actionButton.title = insight.action?.title ?? ""
        self.needsDisplay = true
        self.layoutSubtreeIfNeeded()
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = self.severity.color.withAlphaComponent(0.1).cgColor
            self.layer?.borderColor = self.severity.color.withAlphaComponent(0.28).cgColor
        }
    }

    @objc private func performAction() {
        self.action?.perform()
    }
}

/// Small filled dot drawn in a severity color, for the menu bar health item.
public func healthDotImage(_ severity: Severity, size: CGFloat = 16) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let d: CGFloat = size * 0.56
        let circle = NSRect(x: (rect.width - d) / 2, y: (rect.height - d) / 2, width: d, height: d)
        severity.color.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: circle.insetBy(dx: -size * 0.12, dy: -size * 0.12)).fill()
        severity.color.setFill()
        NSBezierPath(ovalIn: circle).fill()
        return true
    }
    image.isTemplate = false
    return image
}
