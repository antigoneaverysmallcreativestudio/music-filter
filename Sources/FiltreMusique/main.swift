import AppKit
import Darwin

MainActor.assumeIsolated {
    configureInterfaceLanguage()
    if let result = LaunchAtLogin.handleCommandLineIfNeeded() {
        exit(result)
    }
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { application.run() }
}
