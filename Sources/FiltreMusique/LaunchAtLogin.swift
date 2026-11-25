import AppKit
import CoreServices
import ServiceManagement

@MainActor
final class LaunchAtLogin {
    enum State: String {
        case enabled
        case disabled
        case approvalRequired = "approval-required"
        case unavailable
    }

    var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .approvalRequired
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            // A registered item awaiting approval can only be enabled by the user.
            guard service.status != .enabled, service.status != .requiresApproval else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func isLoginLaunch(
        _ event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> Bool {
        guard let event,
              event.eventClass == kCoreEventClass,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    static func handleCommandLineIfNeeded() -> Int32? {
        let flags: Set<String> = [
            "--login-status",
            "--enable-launch-at-login",
            "--disable-launch-at-login"
        ]
        let commands = CommandLine.arguments.dropFirst().filter { flags.contains($0) }
        guard !commands.isEmpty else { return nil }

        let login = LaunchAtLogin()
        guard commands.count == 1, let command = commands.first else {
            print(login.state.rawValue)
            writeError(L("Specify only one launch-at-login command.", "Indiquez une seule commande de démarrage à la connexion."))
            return 1
        }

        do {
            switch command {
            case "--enable-launch-at-login": try login.setEnabled(true)
            case "--disable-launch-at-login": try login.setEnabled(false)
            default: break
            }
        } catch {
            let actual = login.state
            print(actual.rawValue)
            writeError(interfaceErrorDescription(error))
            return actual == .approvalRequired ? 2 : 1
        }

        let actual = login.state
        print(actual.rawValue)
        if actual == .approvalRequired { return 2 }
        if actual == .unavailable { return 1 }
        switch command {
        case "--enable-launch-at-login": return actual == .enabled ? 0 : 1
        case "--disable-launch-at-login": return actual == .disabled ? 0 : 1
        default: return 0
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
