import AppKit

// Compiled and run only by check-localization.py inside an isolated fixture
// bundle. No production app, visible window, status item or Music command runs.
@main
struct LocalizationCheck {
    @MainActor
    static func main() throws {
        let mode = ProcessInfo.processInfo.environment["MUSIC_FILTER_LANGUAGE_CHECK"] ?? "external"
        let requested = Locale.preferredLanguages
        if mode == "runtime" { configureInterfaceLanguage() }
        let bundle = Bundle.main
        var result: [String: Any] = [
            "requested": requested,
            "effective": Locale.preferredLanguages,
            "preferredLocalizations": bundle.preferredLocalizations,
            "name": bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "",
            "displayName": bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "",
            "permission": bundle.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String ?? ""
        ]
        if mode == "runtime" {
            NSApplication.shared.setActivationPolicy(.prohibited)
            result["layoutDirection"] = NSApplication.shared.userInterfaceLayoutDirection == .leftToRight ? "ltr" : "rtl"
            let menu = StatusMenuController()
            menu.update(track: nil, enabled: true, status: "", count: 0, lastSkipped: nil)
            result["mainMenu"] = menu.menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            result["settings"] = menu.menu.items.compactMap(\.submenu).flatMap(\.items)
                .filter { !$0.isSeparatorItem && $0.action != nil }.map(\.title)
            result["recentMenu"] = menu.recentExclusionMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            let exclusions = ExclusionsWindowController()
            result["windowTitle"] = exclusions.window?.title ?? ""
            result["windowVisible"] = exclusions.window?.isVisible ?? false
            result["windowText"] = text(in: exclusions.window?.contentView)
            let views = allViews(in: exclusions.window?.contentView)
            guard let transfer = views.first(where: { $0.accessibilityIdentifier() == "exclusions.transferOptionsButton" }) as? NSPopUpButton,
                  let sidebar = transfer.superview,
                  let split = views.first(where: { $0.accessibilityIdentifier() == "exclusions.sidebarSplit" }) as? NSSplitView,
                  let search = views.first(where: { $0.accessibilityIdentifier() == "exclusions.searchField" }) as? NSTextField,
                  let recentCount = views.first(where: { $0.accessibilityIdentifier() == "exclusions.songs.recentCount" }) as? NSTextField,
                  let totalCount = views.first(where: { $0.accessibilityIdentifier() == "exclusions.songs.count" }) as? NSTextField,
                  let recentHeading = views.first(where: { $0.accessibilityIdentifier() == "exclusions.songs.recentHeading" }),
                  let content = views.first(where: { $0.accessibilityIdentifier() == "exclusions.content" }),
                  let transferMenu = transfer.menu else {
                preconditionFailure("Missing exclusion options/count controls")
            }
            precondition(!views.contains { $0.accessibilityIdentifier() == "exclusions.exportButton" })
            // The first pull-down item is the ellipsis image, not a command.
            let transferItems = transferMenu.items.dropFirst().filter { !$0.isSeparatorItem }
            let transferTitles = transferItems.map(\.title)
            precondition(transferTitles == [L("Export exclusions…", "Exporter les exclusions…"),
                                           L("Import exclusions…", "Importer les exclusions…"),
                                           L("Delete all exclusions…", "Supprimer toutes les exclusions…")])
            precondition(transferMenu.items[3].isSeparatorItem)
            precondition(transfer.accessibilityLabel() == L("More options", "Plus d’options"))
            let deleteItem = transferItems[2]
            precondition(!deleteItem.isEnabled, "Empty lists must disable deletion")
            result["transferMenu"] = transferTitles
            result["transferAccessibilityLabel"] = transfer.accessibilityLabel() ?? ""
            var transferWidths: [String: Double] = [:]
            for width in [104, 176, 220] {
                split.setPosition(CGFloat(width), ofDividerAt: 0)
                exclusions.window?.contentView?.layoutSubtreeIfNeeded()
                let frame = transfer.convert(transfer.bounds, to: sidebar)
                let bottom = sidebar.isFlipped ? sidebar.bounds.maxY - frame.maxY : frame.minY
                precondition(abs(frame.minX - 16) < 0.1 && abs(bottom - 16) < 0.1)
                precondition(frame.maxX <= sidebar.bounds.width - 9)
                precondition(frame.size == NSSize(width: 32, height: 32))
                let titleFrame = recentHeading.convert(recentHeading.bounds, to: content)
                let titleTop = content.isFlipped ? titleFrame.minY : content.bounds.maxY - titleFrame.maxY
                precondition(abs(titleTop - 18) < 0.1)
                transferWidths[String(width)] = frame.width
            }
            result["transferWidths"] = transferWidths
            var importRequests = 0
            var exportRequests = 0
            var deleteRequests = 0
            exclusions.onImport = { importRequests += 1 }
            exclusions.onExport = { exportRequests += 1 }
            exclusions.onDeleteAll = { deleteRequests += 1 }
            // Even a stale action dispatched after the last rule disappeared
            // must not open a destructive confirmation.
            precondition(NSApp.sendAction(deleteItem.action!, to: deleteItem.target, from: deleteItem))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            precondition(deleteRequests == 0)
            let songs = (0..<27).map { index in
                BanRule(kind: .track, name: "Fixture song \(index)", artist: "Fixture artist",
                        createdAt: Date(timeIntervalSince1970: Double(100 - index)))
            }
            let fixtures = songs + [BanRule(kind: .artist, name: "Fixture artist"),
                                   BanRule(kind: .album, name: "Fixture album", artist: "Fixture artist")]
            exclusions.update(rules: fixtures)
            precondition(deleteItem.isEnabled)
            precondition(recentCount.stringValue == L("3 songs", "3 morceaux"))
            precondition(totalCount.stringValue == L("27 songs", "27 morceaux"))
            precondition(recentCount.font == totalCount.font && recentCount.textColor == totalCount.textColor)
            for (query, expectedRecent, expectedTotal) in [("Fixture song 0", 1, 1), ("Fixture song 26", 0, 1), ("Missing", 0, 0)] {
                search.stringValue = query
                exclusions.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
                func count(_ n: Int) -> String { n == 1 ? L("1 song", "1 morceau") : L("\(n) songs", "\(n) morceaux") }
                precondition(recentCount.stringValue == count(expectedRecent))
                precondition(totalCount.stringValue == count(expectedTotal))
                precondition(deleteItem.isEnabled, "Deletion applies to the whole store, not filtered results")
            }
            result["songCounts"] = ["recent": 3, "all": 27, "filteredRecent": 0, "filteredAll": 0]
            // Invoke only fixture callbacks; no file panel or user-data write.
            for item in transferItems {
                precondition(item is AccessibleMenuItem && item.view is MenuActionRow)
                guard let action = item.action else { preconditionFailure("Missing options action") }
                precondition(NSApp.sendAction(action, to: item.target, from: item))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            precondition(importRequests == 1 && exportRequests == 1 && deleteRequests == 1)
            result["transferCallbacks"] = ["import": importRequests, "export": exportRequests, "delete": deleteRequests]
            exclusions.menuWillOpen(transferMenu)
            for item in transferItems {
                exclusions.menu(transferMenu, willHighlight: item)
                precondition(transferItems.allSatisfy { ($0.view as? MenuActionRow)?.highlighted == ($0 === item) })
            }
            // Save optional offscreen row renderings for neutral-hover/red-text
            // review without displaying a menu or activating any application.
            if let directory = ProcessInfo.processInfo.environment["MUSIC_FILTER_MENU_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                    for (index, item) in transferItems.enumerated() {
                        guard let row = item.view as? MenuActionRow else { continue }
                        row.appearance = NSAppearance(named: appearanceName)
                        row.highlighted = true
                        guard let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { continue }
                        row.cacheDisplay(in: row.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(interfaceLanguageCode(for: Locale.preferredLanguages))-\(appearanceName.rawValue)-\(index).png"))
                        }
                    }
                }
            }
            exclusions.menuDidClose(transferMenu)
            precondition(transferItems.allSatisfy { ($0.view as? MenuActionRow)?.highlighted == false })
            result["windowVisibleAfterActions"] = exclusions.window?.isVisible ?? false
            precondition(exclusions.window?.isVisible == false)
            result["error"] = interfaceErrorDescription(BanStoreError.emptyArtist)
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    @MainActor
    private static func text(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var values: [String] = []
        if let field = view as? NSTextField {
            if !field.stringValue.isEmpty { values.append(field.stringValue) }
            if let placeholder = field.placeholderString, !placeholder.isEmpty { values.append(placeholder) }
        }
        if let button = view as? NSButton, !button.title.isEmpty { values.append(button.title) }
        return values + view.subviews.flatMap { text(in: $0) }
    }

    @MainActor
    private static func allViews(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { allViews(in: $0) }
    }
}
