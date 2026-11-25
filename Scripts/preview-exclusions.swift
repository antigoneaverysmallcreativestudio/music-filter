import AppKit

/// Isolated fixture app for the production exclusions window. It never creates
/// a BanStore, MusicController, login item, or persistent user preference.
/// No artwork provider or network request is used by this fixture preview.
@main
@MainActor
final class ExclusionsPreviewApp: NSObject, NSApplicationDelegate {
    private let manager = ExclusionsWindowController()
    private var fixtures = makeFixtures()
    private var appearanceItems: [NSMenuItem] = []

    static func main() {
        let application = NSApplication.shared
        let delegate = ExclusionsPreviewApp()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        manager.onUnblock = { [weak self] id in
            guard let self else { return }
            self.fixtures.removeAll { $0.id == id }
            self.manager.update(rules: self.fixtures)
        }
        manager.update(rules: fixtures)
        manager.window?.title = "Music Filter — Exclusions Preview"
        manager.showCentered()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static func makeFixtures() -> [BanRule] {
        // Public names verified against Apple's FR catalog. These are examples
        // for UI testing, not the user's real exclusions.
        let values: [(BanRule.Kind, String, String?, String?)] = [
            (.artist, "Odezenne", nil, nil),
            (.artist, "Daft Punk", nil, nil),
            (.artist, "Bonobo", nil, nil),
            (.album, "1200 mètres en tout", "Odezenne", nil),
            (.album, "Discovery", "Daft Punk", nil),
            (.album, "Black Sands", "Bonobo", nil),
            (.album, "Mezzanine", "Massive Attack", nil),
            (.track, "Caprice", "Odezenne", "1200 mètres en tout"),
            (.track, "Regarde si c'est loin", "Odezenne", "1200 mètres en tout"),
            (.track, "One More Time", "Daft Punk", "Discovery"),
            (.track, "Harder Better Faster Stronger", "Daft Punk", "Discovery"),
            (.track, "Kiara", "Bonobo", "Black Sands"),
            (.track, "Eyesdown (feat. Andreya Triana)", "Bonobo", "Black Sands")
        ]
        let now = Date()
        // Recent means the latest three exclusions, even when several are
        // older than three days; searching must never backfill older matches.
        let songAges: [TimeInterval] = [0.2, 4.0, 12.0, 30.0, 60.0, 90.0]
        let albumAges: [TimeInterval] = [1.0, 8.0, 20.0, 40.0]
        var fixtures = values.enumerated().map { index, entry in
            let identifier = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            let age = entry.0 == .track ? songAges[index - 7]
                : (entry.0 == .album ? albumAges[index - 3] : 10)
            return BanRule(id: identifier, kind: entry.0, name: entry.1,
                           artist: entry.2, album: entry.3,
                           createdAt: now.addingTimeInterval(-age * 24 * 60 * 60))
        }
        // Older fictional entries make the complete Songs list overflow while
        // leaving the three recent identities unchanged for scroll inspection.
        fixtures += (1...12).map { index in
            BanRule(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index))!,
                    kind: .track, name: L("Preview song \(index)", "Morceau de démonstration \(index)"),
                    artist: L("Example artist", "Artiste de démonstration"),
                    album: L("Example album", "Album de démonstration"),
                    createdAt: now.addingTimeInterval(-TimeInterval(100 + index) * 24 * 60 * 60))
        }
        return fixtures
    }

    private func installMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: L("Quit Preview", "Quitter l’aperçu"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("Edit", "Édition"))
        for (title, action, key) in [
            (L("Cut", "Couper"), "cut:", "x"),
            (L("Copy", "Copier"), "copy:", "c"),
            (L("Paste", "Coller"), "paste:", "v"),
            (L("Select All", "Tout sélectionner"), "selectAll:", "a")
        ] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)

        let appearanceItem = NSMenuItem()
        let appearance = NSMenu(title: L("Appearance", "Apparence"))
        appearance.autoenablesItems = false
        for (index, title) in [L("System", "Système"), L("Light", "Clair"), L("Dark", "Sombre")].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == 0 ? .on : .off
            appearance.addItem(item)
            appearanceItems.append(item)
        }
        appearanceItem.submenu = appearance
        main.addItem(appearanceItem)
        NSApp.mainMenu = main
    }

    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        // Deliberately scoped to this one preview window, never NSApp or the OS.
        switch sender.tag {
        case 1: manager.window?.appearance = NSAppearance(named: .aqua)
        case 2: manager.window?.appearance = NSAppearance(named: .darkAqua)
        default: manager.window?.appearance = nil
        }
        for item in appearanceItems { item.state = item === sender ? .on : .off }
    }
}
