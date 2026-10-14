//
//  helpers.swift
//  Status
//

import Cocoa
import Kit
import Net
import UserNotifications

extension AppDelegate {
    internal func parseArguments() {
        let args = CommandLine.arguments
        
        if args.contains("--reset") {
            debug("Receive --reset argument. Resetting store (UserDefaults)...")
            Store.shared.reset()
        }
        
        if let disableIndex = args.firstIndex(of: "--disable") {
            if args.indices.contains(disableIndex+1) {
                let disableModules = args[disableIndex+1].split(separator: ",")
                
                disableModules.forEach { (moduleName: Substring) in
                    if let module = modules.first(where: { $0.config.name.lowercased() == moduleName.lowercased()}) {
                        module.unmount()
                    }
                }
            }
        }
    }
    
    internal func parseVersion() {
        let key = "version"
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if Store.shared.string(key: key, defaultValue: "") != currentVersion {
            debug("Current version (\(currentVersion)) set")
            Store.shared.set(key: key, value: currentVersion)
        }
    }
    
    internal func defaultValues() {
        if Store.shared.exist(key: "runAtLoginInitialized") {
            LaunchAtLogin.migrate()
        }
        
        if Store.shared.exist(key: "dockIcon") {
            let dockIconStatus = Store.shared.bool(key: "dockIcon", defaultValue: false) ? NSApplication.ActivationPolicy.regular : NSApplication.ActivationPolicy.accessory
            NSApp.setActivationPolicy(dockIconStatus)
        }
    }
    
    internal func setup(completion: @escaping () -> Void) {
        if Store.shared.exist(key: "setupProcess") || Store.shared.exist(key: "runAtLoginInitialized") {
            completion()
            return
        }
        
        debug("showing the setup window")
        
        let window = self.ensureSetupWindow()
        window.show()
        window.finishHandler = {
            debug("setup is finished, starting the app")
            completion()
        }
        Store.shared.set(key: "setupProcess", value: true)
    }
    
    @objc internal func listenForAppPause() {
        for m in modules {
            if self.pauseState && m.enabled {
                m.disable()
            } else if !self.pauseState && !m.enabled && Store.shared.bool(key: "\(m.config.name)_state", defaultValue: m.config.defaultState) {
                m.enable()
            }
        }
        self.icon()
    }
    
    internal func icon() {
        if self.pauseState {
            self.menuBarItem = NSStatusBar.system.statusItem(withLength: AppIcon.size.width)
            DispatchQueue.main.async(execute: {
                self.menuBarItem?.autosaveName = "Status"
            })
            self.menuBarItem?.button?.addSubview(AppIcon())
            
            self.menuBarItem?.button?.target = self
            self.menuBarItem?.button?.action = #selector(self.openSettings)
            self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        } else {
            if let item = self.menuBarItem {
                NSStatusBar.system.removeStatusItem(item)
            }
            self.menuBarItem = nil
        }
    }
    
    @objc internal func openSettings() {
        NotificationCenter.default.post(name: .toggleSettings, object: nil, userInfo: ["module": "Dashboard"])
    }
    
    internal func handleKeyEvent(_ event: NSEvent) {
        var keyCodes: [UInt16] = []
        if event.modifierFlags.contains(.control) { keyCodes.append(59) }
        if event.modifierFlags.contains(.shift) { keyCodes.append(60) }
        if event.modifierFlags.contains(.command) { keyCodes.append(55) }
        if event.modifierFlags.contains(.option) { keyCodes.append(58) }
        keyCodes.append(event.keyCode)
        
        guard !keyCodes.isEmpty,
              let module = modules.first(where: { $0.enabled && $0.popupKeyboardShortcut == keyCodes }),
              let widget = module.menuBar.widgets.filter({ $0.isActive }).first,
              let window = widget.item.window else { return }
        
        NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
            "module": module.name,
            "widget": widget.type,
            "origin": window.frame.origin,
            "center": window.frame.width/2
        ])
    }
    
    // Workaround for the WindowServer "Invalid window" log spam on macOS Tahoe (#3212, #2829).
    //
    // On Tahoe every layout pass on an NSStatusBarWindow schedules a tiling-constraints sync
    // (-[NSWindow(NSFullScreen) _refreshTilingConstraints:]) that calls
    // SLSPackagesSetWindowConstraints with the window number. A status bar window has no regular
    // server-side window on Tahoe (the low 32 bits of its windowNumber are zero), so WindowServer
    // rejects every call and logs "_CGXPackagesSetWindowConstraints: Invalid window" on each
    // widget update. The gate (-[NSWindow(NSFullScreen) _needsTilingConstraintUpdate]) returns
    // true whenever the app is inactive, which for a menu bar app is almost always.
    //
    // Overriding the gate on NSStatusBarWindow only (a status bar window can never be tiled)
    // stops the sync from ever being scheduled; all other windows keep the default behavior.
    internal func suppressStatusBarTilingConstraintUpdates() {
        guard #available(macOS 26.0, *) else { return }
        let selector = NSSelectorFromString("_needsTilingConstraintUpdate")
        guard let cls = NSClassFromString("NSStatusBarWindow"),
              let method = class_getInstanceMethod(cls, selector) else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in false }
        class_addMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }
}

#if DEBUG
// Debug-only: `--snapshot <dir>` renders every popup and settings page to PNG files for UI review.
extension AppDelegate {
    internal func runSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--snapshot"), args.indices.contains(idx+1) else { return }
        let dir = URL(fileURLWithPath: args[idx+1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let appearances: [NSAppearance.Name] = [.darkAqua, .aqua]
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var steps: [() -> Void] = []
            for name in appearances {
                steps.append {
                    NSApp.appearance = NSAppearance(named: name)
                    _ = HealthCenter.shared.debugShowPopover()
                }
                steps.append {}
                steps.append {}
                steps.append {}
                steps.append {}
                steps.append {
                    if let w = HealthCenter.shared.debugShowPopover() {
                        self.snapshot(w.contentView, to: dir.appendingPathComponent("health-\(name == .darkAqua ? "dark" : "light").png"), dark: name == .darkAqua)
                    }
                    HealthCenter.shared.debugToggle()
                }
            }
            steps.append {
                for (i, w) in NSApp.windows.enumerated() where NSStringFromClass(type(of: w)).contains("StatusBar") && w.isVisible {
                    self.snapshot(w.contentView, to: dir.appendingPathComponent("menubar-\(i).png"), dark: true)
                }
            }
            for name in appearances {
                let suffix = name == .darkAqua ? "dark" : "light"
                for m in modules where m.available && m.enabled {
                    guard let w = m.debugPopupWindow else { continue }
                    steps.append {
                        NSApp.appearance = NSAppearance(named: name)
                        w.setFrameOrigin(NSPoint(x: 40, y: 40))
                        w.setIsVisible(true)
                    }
                    if m.config.name == "CPU" { steps.append {}; steps.append {}; steps.append {} }
                    steps.append {
                        self.snapshot(w.contentView, to: dir.appendingPathComponent("popup-\(m.config.name)-\(suffix).png"), dark: name == .darkAqua)
                        w.setIsVisible(false)
                    }
                }
                let pages = ["Dashboard", "History", "Settings"] + modules.filter({ $0.available }).map({ $0.config.name })
                for page in pages {
                    steps.append {
                        NSApp.appearance = NSAppearance(named: name)
                        let w = self.ensureSettingsWindow()
                        w.open(module: nil)
                        NotificationCenter.default.post(name: .openModuleSettings, object: nil, userInfo: ["module": page])
                    }
                    steps.append {
                        let w = self.ensureSettingsWindow()
                        self.snapshot(w.contentView, to: dir.appendingPathComponent("settings-\(page)-\(suffix).png"), dark: name == .darkAqua)
                    }
                }
            }
            for name in appearances {
                steps.append {
                    NSApp.appearance = NSAppearance(named: name)
                    _ = Network.debugConnectionsWindow()
                }
                steps.append {}
                steps.append {}
                steps.append {
                    if let w = Network.debugConnectionsWindow() {
                        self.snapshot(w.contentView, to: dir.appendingPathComponent("connections-\(name == .darkAqua ? "dark" : "light").png"), dark: name == .darkAqua)
                    }
                }
            }
            steps.append { exit(0) }
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2, execute: step)
            }
        }
    }
    
    private func snapshot(_ view: NSView?, to url: URL, dark: Bool) {
        guard let view, let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        
        // Capture our own window from the window server (no screen-recording permission needed for own windows).
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        var cgImage: CGImage?
        if let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") {
            let fn = unsafeBitCast(sym, to: CreateImage.self)
            // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0, BestResolution = 1 << 3
            cgImage = fn(.null, 1 << 3, UInt32(truncatingIfNeeded: window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
        }
        if cgImage == nil, let layer = view.layer {
            let scale = window.backingScaleFactor
            let size = view.bounds.size
            if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                ctx.setFillColor((dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
                layer.render(in: ctx)
                cgImage = ctx.makeImage()
            }
        }
        guard let cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}

extension AppDelegate {
    // Debug-only: `--widget-test <dir>` turns on every widget of every module and records what each draws.
    internal func runWidgetTestIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--widget-test"), args.indices.contains(idx+1) else { return }
        let dir = URL(fileURLWithPath: args[idx+1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for m in modules where m.available {
                if !m.enabled { m.enable() }
                m.menuBar.widgets.forEach { $0.toggle(true) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                var report = ""
                for m in modules where m.available {
                    for w in m.menuBar.widgets {
                        let view = w.item
                        let inMenuBar = view.window != nil
                        let width = view.frame.width
                        report += "\(m.config.name)\t\(w.type.rawValue)\tactive=\(w.isActive)\tinMenuBar=\(inMenuBar)\twidth=\(Int(width))\n"
                        guard width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: dir.appendingPathComponent("\(m.config.name)-\(w.type.rawValue).png"))
                        }
                    }
                }
                try? report.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
                exit(0)
            }
        }
    }
}
#endif
