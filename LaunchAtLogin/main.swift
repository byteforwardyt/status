//
//  main.swift
//  Status
//

import Cocoa

func main() {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
        exit(1)
    }
    let mainBundleId = bundleIdentifier.replacingOccurrences(of: ".LaunchAtLogin", with: "")
    
    if !NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleId).isEmpty {
        exit(0)
    }
    
    let pathComponents = (Bundle.main.bundlePath as NSString).pathComponents
    guard pathComponents.count >= 5 else {
        exit(1)
    }
    let mainPath = NSString.path(withComponents: Array(pathComponents[0...(pathComponents.count - 5)]))
    NSWorkspace.shared.openApplication(at: NSURL.fileURL(withPath: mainPath), configuration: NSWorkspace.OpenConfiguration(), completionHandler: { _, _ in
        exit(0)
    })
}

main()
