import AppKit

// Isolated component checks: no windows, menu tracking UI, or Music commands.
// Run from the repository root:
// xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
//   Sources/FiltreCore/*.swift Sources/FiltreMusique/MainViewController.swift \
//   Scripts/check-menu-behavior.swift -o /tmp/music-filter-menu-check
// /tmp/music-filter-menu-check
// /tmp/music-filter-menu-check --settings-only

@main
struct MenuBehaviorCheck {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let checks = Checks()
        if CommandLine.arguments.contains("--settings-only") {
            try checks.startupOptionsChecks()
            try checks.preemptiveOptionsChecks()
            print("PASS: \(checks.count) settings checks; no UI shown and no Music commands sent.")
            return
        }
        try checks.snapshotAndActionChecks()
        try checks.longNameAndMarqueeChecks()
        try checks.startupOptionsChecks()
        try checks.savedIconAppearanceChecks()
        try checks.preemptiveOptionsChecks()
        try checks.writeOffscreenPreview()
        print("PASS: \(checks.count) menu checks; no UI shown and no Music commands sent.")
    }
}

@MainActor
private final class Checks {
    private(set) var count = 0
    private let font = NSFont.menuFont(ofSize: 0)
    private let prefixes = [L("Exclude song", "Exclure le morceau"), L("Exclude album", "Exclure l’album"), L("Exclude artist", "Exclure l’artiste")]

    private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(message: message) }
        count += 1
    }

    func snapshotAndActionChecks() throws {
        let controller = StatusMenuController()
        let menu = controller.menu
        let rows = (0..<3).map { menu.item(at: $0)! }
        let first = TrackSnapshot(id: "A", title: "First song", artist: "Maÿ", albumArtist: "First album artist", album: "First album", isPlaying: true)
        let second = TrackSnapshot(id: "B", title: "Second song", artist: "Another artist", albumArtist: "Second album artist", album: "Second album", isPlaying: true)
        var actions = [[TrackSnapshot](), [TrackSnapshot](), [TrackSnapshot]()]
        var openings = 0
        var managements = 0
        controller.onManage = { managements += 1 }
        controller.onBanTrack = { actions[0].append($0) }
        controller.onBanAlbum = { actions[1].append($0) }
        controller.onBanArtist = { actions[2].append($0) }
        controller.onWillOpen = { openings += 1 }
        controller.update(track: first, enabled: true, status: "", count: 1, lastSkipped: nil)

        try expect(menu.numberOfItems == 10, "Main menu must contain song, album, artist, separator, Manage exclusions, separator, Settings, separator, About, Quit.")
        try expect(menu.item(at: 3)?.isSeparatorItem == true && menu.item(at: 5)?.isSeparatorItem == true && menu.item(at: 7)?.isSeparatorItem == true, "Separator positions changed.")
        try expect(menu.item(at: 4)?.action == Selector(("manage")) && menu.item(at: 6)?.submenu != nil && menu.item(at: 8)?.action == Selector(("about")) && menu.item(at: 9)?.action == Selector(("quit")), "Manage exclusions, Settings, About or Quit is missing or out of order.")
        try expect(menu.minimumWidth == 0, "The main menu must not impose a wide minimum width.")
        menu.performActionForItem(at: 4)
        try expect(managements == 1 && actions.allSatisfy { $0.isEmpty }
            && menu.item(at: 4)?.title == L("Manage exclusions", "Gérer les exclusions") + " (1)",
            "The direct management action must retain its count and never dispatch an exclusion.")
        for (index, name) in [first.title, first.album, first.artist].enumerated() {
            try expect(rows[index].view == nil, "Action row must remain a native NSMenuItem.")
            try expect(rows[index].title == "\u{fffc}" + prefixes[index] + "\u{fffc}" + name, "Wrong action order or inline metadata at row \(index): \(rows[index].title.debugDescription).")
            try expect(rows[index].isEnabled, "Complete metadata must enable all three actions.")
            try expect(rows[index].toolTip == nil, "Ban actions must not have tooltips.")
        }
        try expect(menu.item(at: 6)?.toolTip == nil, "Settings must not have a tooltip.")
        let initialTitles = rows.map(\.title)
        let initialAX = rows.map { $0.accessibilityLabel() }
        controller.menuWillOpen(menu)
        controller.update(track: second, enabled: true, status: "", count: 1, lastSkipped: nil)
        try expect(rows.map(\.title) == initialTitles, "Polling changed targets during a menu visit.")
        try expect(rows.map { $0.accessibilityLabel() } == initialAX, "Polling changed accessibility targets during tracking.")

        // AppKit can deliver an action after closing and after a subsequent poll.
        controller.menuDidClose(menu)
        controller.update(track: second, enabled: true, status: "", count: 1, lastSkipped: nil)
        for index in 0..<3 { menu.performActionForItem(at: index) }
        for index in 0..<3 {
            try expect(actions[index] == [first], "A delayed action used a newer playback snapshot.")
        }
        controller.menuWillOpen(menu)
        for (index, name) in [second.title, second.album, second.artist].enumerated() {
            try expect(rows[index].title == "\u{fffc}" + prefixes[index] + "\u{fffc}" + name, "Reopening did not display the latest target.")
            menu.performActionForItem(at: index)
            try expect(actions[index] == [first, second], "Reopened action did not dispatch its own captured snapshot.")
        }
        try expect(openings == 2, "Opening callback must run once per visit.")
        controller.menuDidClose(menu)

        let noAlbum = TrackSnapshot(id: "C", title: "Song without album", artist: "Known artist", isPlaying: false)
        controller.update(track: noAlbum, enabled: true, status: "", count: 1, lastSkipped: nil)
        controller.menuWillOpen(menu)
        try expect(rows[0].isEnabled && !rows[1].isEnabled && rows[2].isEnabled && rows[1].attributedTitle?.string == "\u{fffc}" + prefixes[1], "Missing album must disable only its action and retain its inline icon, including when playback is paused.")
        try expect(rows[1].accessibilityLabel() == L("No album detected in Music", "Aucun album détecté dans Musique"), "Missing album has misleading accessibility text.")
        controller.menuDidClose(menu)

        controller.update(track: nil, enabled: true, status: "", count: 0, lastSkipped: nil)
        controller.menuWillOpen(menu)
        try expect(rows.enumerated().allSatisfy { !$0.element.isEnabled && $0.element.image == nil && $0.element.attributedTitle?.string == "\u{fffc}" + prefixes[$0.offset] }, "Missing metadata must disable all ban actions while retaining their inline icons.")
        for index in 0..<3 { menu.performActionForItem(at: index) }
        try expect(actions.allSatisfy { $0.count == 2 } && menu.item(at: 4)?.title == L("Manage exclusions", "Gérer les exclusions") + " (0)", "Missing metadata dispatched a stale target or prevented the management count from updating.")
        controller.menuDidClose(menu)
    }

    func longNameAndMarqueeChecks() throws {
        let controller = StatusMenuController()
        let menu = controller.menu
        let rows = (0..<3).map { menu.item(at: $0)! }
        let artist = "Maÿ 👩🏽‍🚀 e\u{301} 🇫🇷 " + String(repeating: "Long credited artist name 🧑🏽‍🎤 ", count: 4)
        let song = "A long song 👨‍👩‍👧‍👦 with Unicode e\u{301} " + String(repeating: "and another movement 🇫🇷 ", count: 4)
        let album = "An extended album 🎼 " + String(repeating: "Volume two and more ", count: 5)
        let track = TrackSnapshot(id: "long", title: song, artist: artist, albumArtist: "Album credit", album: album, isPlaying: true)
        let started = ProcessInfo.processInfo.systemUptime
        controller.update(track: track, enabled: true, status: "", count: 1, lastSkipped: nil)
        print(String(format: "Long-name attachment preparation: %.1f ms", (ProcessInfo.processInfo.systemUptime - started) * 1_000))
        let names = [clean(song), clean(album), clean(artist)]
        for index in 0..<3 {
            try expect(rows[index].view == nil, "Overflow text must not replace the native menu row.")
            try expect(rows[index].attributedTitle?.string == "\u{fffc}" + prefixes[index] + "\u{fffc}\u{fffc}", "The inline icon and action must precede the separator attachment and metadata attachment.")
            let image = try attachmentImage(rows[index])
            let title = try attributedTitle(rows[index])
            try expect(image.size.width > 0 && image.size.height > 0, "Attachment image has no dimensions.")
            try expect(title.size().width <= 300.5, "Attributed title exceeded its 300 pt width budget.")
            try expect(rows[index].accessibilityLabel()?.contains(names[index]) == true, "Accessibility lost full Unicode metadata.")
            try expect(rows[index].toolTip == nil, "Overflow text must not add a tooltip.")
        }
        try expect(rows[0].accessibilityLabel()?.hasSuffix(clean(artist)) == true, "Song accessibility lost the credited artist.")
        try expect(rows[1].accessibilityLabel()?.hasSuffix("Album credit") == true, "Album accessibility lost its album credit.")
        let labels = rows.map { $0.accessibilityLabel() }
        let widths = try rows.map { try attributedTitle($0).size().width }
        let menuWidth = menu.size.width
        try expect(timer(in: controller) == nil, "A timer started while the menu was closed.")
        controller.menuWillOpen(menu)
        try expect(timer(in: controller) == nil, "A timer started without a highlighted row.")
        controller.menu(menu, willHighlight: rows[2])
        let initialArtistRaster = try rasterData(attachmentImage(rows[2]))
        let initialSongRaster = try rasterData(attachmentImage(rows[0]))
        let initialAlbumRaster = try rasterData(attachmentImage(rows[1]))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try expect(timer(in: controller) == nil, "Reduced motion must prevent the timer.")
            pumpRunLoop(for: 1.25)
            try expect(try rasterData(attachmentImage(rows[2])) == initialArtistRaster, "Reduced motion changed the raster.")
            print("Reduce Motion enabled: static attachment behavior checked.")
        } else {
            try expect(timer(in: controller)?.isValid == true, "Highlighted overflow text did not start a timer.")
            pumpRunLoop(for: 1.35)
            try expect(try rasterData(attachmentImage(rows[2])) != initialArtistRaster, "The attachment raster did not move after the start delay.")
            try expect(try rasterData(attachmentImage(rows[0])) == initialSongRaster, "An unhighlighted song row moved.")
            try expect(try rasterData(attachmentImage(rows[1])) == initialAlbumRaster, "An unhighlighted album row moved.")
            print("Reduce Motion disabled: smooth attachment raster changes checked.")
        }
        try expect(try rows.map { try attributedTitle($0).size().width } == widths, "Animation changed row widths.")
        try expect(menu.size.width == menuWidth, "Animation resized the native menu.")
        try expect(rows.map { $0.accessibilityLabel() } == labels, "Animation changed full accessibility labels.")
        try expect(rows.allSatisfy { $0.toolTip == nil } && menu.item(at: 6)?.toolTip == nil, "Animation added a tooltip.")
        for index in 0..<3 {
            try expect(rows[index].attributedTitle?.string == "\u{fffc}" + prefixes[index] + "\u{fffc}\u{fffc}", "The inline icon, action prefix or separator changed during scrolling.")
        }
        controller.menu(menu, willHighlight: menu.item(at: 6))
        try expect(timer(in: controller) == nil, "Moving to Settings left a marquee timer.")
        controller.menu(menu, willHighlight: rows[0])
        let activeTimer = timer(in: controller)
        controller.menuDidClose(menu)
        try expect(timer(in: controller) == nil && activeTimer?.isValid != true, "Closing the menu left a valid timer.")
        let closedRaster = try rasterData(attachmentImage(rows[0]))
        pumpRunLoop(for: 0.1)
        try expect(try rasterData(attachmentImage(rows[0])) == closedRaster, "A closed menu continued rendering animation frames.")
        try expect(try rows.map { try attributedTitle($0).size().width } == widths, "Closing changed title widths.")
        try expect(menu.size.width == menuWidth, "Closing resized the native menu.")
    }

    func startupOptionsChecks() throws {
        let controller = StatusMenuController()
        let settings = controller.menu.item(at: 6)!.submenu!
        let selectors = Set(settings.items.compactMap { $0.action.map(NSStringFromSelector) })
        try expect(!selectors.contains("toggleDockSwipe") && !controller.responds(to: NSSelectorFromString("toggleDockSwipe"))
            && settings.items.allSatisfy { !["musicFilter.dockSwipe", "musicFilter.dockSwipeStatus"].contains($0.identifier?.rawValue ?? "") },
            "Music Filter must not retain the separate Dock app's action or help rows.")
        try expect(!selectors.contains("pasteLink") && !selectors.contains("addArtist") && !selectors.contains("openMusic"), "Removed actions reappeared in Settings.")
        try expect(!selectors.contains("toggleLaunchAtLogin"), "Open at login must no longer be a menu action.")
        try expect(!settings.items.contains { ["Open at login", "Ouvrir à la connexion"].contains($0.title) }, "Open at login must not remain as a hidden row.")
        try expect(!selectors.contains("toggleCollaborations") && !controller.responds(to: NSSelectorFromString("toggleCollaborations")), "Collaborations must no longer expose a menu action or selector.")
        try expect(!settings.items.contains { ["Include collaborations (feat.)", "Inclure les collaborations (feats)"].contains($0.title) }, "The collaborations setting must be removed, not merely hidden.")
        let removedIDs: Set<String> = ["musicFilter.menuIcons", "musicFilter.exclusionIconBadges", "musicFilter.previewIndicator"]
        let removedSelectors = ["chooseIconPlacement:", "toggleExclusionIconBadges", "chooseIndicatorPosition:", "previewIndicator"]
        try expect(settings.numberOfItems == 8 && settings.items.filter(\.isSeparatorItem).count == 1
            && settings.items.allSatisfy { $0.submenu == nil && !removedIDs.contains($0.identifier?.rawValue ?? "") }
            && removedSelectors.allSatisfy { !controller.responds(to: NSSelectorFromString($0)) }
            && !selectors.contains("manage"), "Settings must contain only filtering and startup controls, with no management duplicate, appearance tools or preview actions.")
        let followItems = settings.items.filter { $0.action.map(NSStringFromSelector) == "toggleFollowMusic" }
        try expect(followItems.count == 1, "Start with Music must appear exactly once.")
        let follow = followItems[0]
        let approval = settings.items.first { $0.action.map(NSStringFromSelector) == "openLoginSettings" }!
        let lastSeparator = settings.items.lastIndex(where: \.isSeparatorItem)!
        try expect(settings.index(of: follow) == lastSeparator + 1, "Start with Music must follow the bottom separator, not remain in the top group.")
        try expect(settings.index(of: approval) == settings.index(of: follow) + 1, "Conditional login approval must stay next to Start with Music.")
        try expect(follow.title == L("Start with Music", "Démarrer avec Musique"), "Start-with-Music wording changed.")
        controller.setStartupOptions(launchAtLogin: true, needsApproval: false, followMusic: true)
        try expect(follow.state == .on && approval.isHidden, "Enabled start-with-Music state is not reflected.")
        let bottomVisible = settings.items[(lastSeparator + 1)...].filter { !$0.isHidden }
        try expect(bottomVisible.count == 1 && bottomVisible.first === follow, "Start with Music must be the sole normal bottom option.")
        controller.setStartupOptions(launchAtLogin: false, needsApproval: true, followMusic: false)
        try expect(follow.state == .mixed && !approval.isHidden, "Pending system approval must show mixed state on Start with Music.")
        controller.setStartupOptions(launchAtLogin: true, needsApproval: false, followMusic: false)
        try expect(follow.state == .off && approval.isHidden, "The internal login registration must not override the follow-Music preference.")
        controller.setStartupOptions(launchAtLogin: false, needsApproval: false, followMusic: false)
        try expect(follow.state == .off && approval.isHidden, "Disabled startup state did not reset.")
        var actions: [String] = []
        controller.onToggleFollowMusic = { actions.append("follow") }
        controller.onOpenLoginSettings = { actions.append("approval") }
        controller.setStartupOptions(launchAtLogin: false, needsApproval: true, followMusic: true)
        for item in [follow, approval] { settings.performActionForItem(at: settings.index(of: item)) }
        try expect(actions == ["follow", "approval"], "Startup callbacks are incorrectly connected.")
    }

    func savedIconAppearanceChecks() throws {
        let controller = StatusMenuController()
        let menu = controller.menu
        let rows = (0..<3).map { menu.item(at: $0)! }
        var targets: [TrackSnapshot] = []
        controller.onBanTrack = { targets.append($0) }
        let first = TrackSnapshot(id: "icons-A", title: "Song A", artist: "Artist A", album: "Album A", isPlaying: true)
        let second = TrackSnapshot(id: "icons-B", title: "Song B", artist: "Artist B", album: "Album B", isPlaying: true)
        controller.update(track: first, enabled: true, status: "", count: 0, lastSkipped: nil)
        controller.menuWillOpen(menu)
        controller.update(track: second, enabled: true, status: "", count: 0, lastSkipped: nil)
        let labels = rows.map { $0.accessibilityLabel() }
        func rowImages() throws -> [NSImage] {
            guard let images = Mirror(reflecting: controller).children.first(where: { $0.label == "rowIcons" })?.value as? [ObjectIdentifier: NSImage],
                  rows.allSatisfy({ images[ObjectIdentifier($0)] != nil }) else {
                throw CheckFailure(message: "Missing action icon images.")
            }
            return rows.map { images[ObjectIdentifier($0)]! }
        }
        func inlineIconRasters(_ placement: MenuIconPlacement) throws -> [Data] {
            guard placement != .hidden else { return [] }
            return try rows.enumerated().map { index, row in
                let title = try attributedTitle(row)
                let offset = placement == .beforeActions ? 0 : (prefixes[index] as NSString).length + 1
                guard let attachment = title.attribute(.attachment, at: offset, effectiveRange: nil) as? NSTextAttachment,
                      let image = attachment.image else { throw CheckFailure(message: "Inline icon attachment is missing.") }
                return try rasterData(image)
            }
        }
        let standardImages = try rowImages()
        let resources = ["exclude-song", "exclude-artist"].compactMap {
            Bundle.main.url(forResource: $0, withExtension: "pdf", subdirectory: "MenuBarIcons")
        }
        try expect(resources.isEmpty || resources.count == 2, "A test bundle must contain both song/artist badge PDFs or none; the album badge uses the shared native composition.")
        // These setters only restore existing preferences; appearance controls
        // and preview actions are intentionally absent from the user menu.
        for placement in [MenuIconPlacement.beforeNames, .hidden, .beforeActions] {
            controller.setIconPlacement(placement)
            try expect(rows.allSatisfy { $0.image == nil }, "All saved icon modes must avoid the invisible native menu-row image slot.")
            for (index, name) in [first.title, first.album, first.artist].enumerated() {
                let attachments = placement == .beforeNames ? "\u{fffc}\u{fffc}" : "\u{fffc}"
                let leadingIcon = placement == .beforeActions ? "\u{fffc}" : ""
                try expect(rows[index].attributedTitle?.string == leadingIcon + prefixes[index] + attachments + name, "Restoring a placement changed metadata or inserted the wrong attachments.")
            }
            try expect(rows.map { $0.accessibilityLabel() } == labels, "Restoring icons must preserve full accessibility targets.")
            let originalTitles = rows.map(\.title)
            let originalRasters = try inlineIconRasters(placement)
            controller.setExclusionIconBadgesEnabled(true)
            let customImages = try rowImages()
            let customRasters = try inlineIconRasters(placement)
            try expect(rows.map(\.title) == originalTitles && rows.map { $0.accessibilityLabel() } == labels
                && customImages.enumerated().allSatisfy { index, image in
                    index != 1 && resources.isEmpty ? image === standardImages[index]
                        : image !== standardImages[index] && image.isTemplate && max(image.size.width, image.size.height) <= 14.01
                }
                && (placement == .hidden || zip(originalRasters, customRasters).enumerated().allSatisfy { index, rasters in
                    index == 1 || !resources.isEmpty ? rasters.0 != rasters.1 : rasters.0 == rasters.1
                }),
                "Restoring the badge preference must use the shared album badge and available song/artist PDFs at 14 pt without changing placement, metadata or accessibility targets.")
            controller.setExclusionIconBadgesEnabled(false)
            try expect((try rowImages()).enumerated().allSatisfy { $0.element === standardImages[$0.offset] }
                && rows.map(\.title) == originalTitles && (try inlineIconRasters(placement)) == originalRasters,
                "Restoring standard icons must restore their exact rasters and titles.")
            menu.performActionForItem(at: 0)
        }
        print(resources.isEmpty ? "Saved minus-sign preference: native album badge and standard song/artist fallbacks checked." : "Saved appearance preferences checked with native album badge and packaged song/artist PDFs; no appearance UI exposed.")
        try expect(targets == [first, first, first], "Restoring appearance preferences dispatched an exclusion or retargeted the menu to newer playback.")
        controller.menuDidClose(menu)

        let long = TrackSnapshot(id: "icons-long", title: String(repeating: "Long song ", count: 12), artist: String(repeating: "Long artist ", count: 12), album: String(repeating: "Long album ", count: 12), isPlaying: true)
        controller.update(track: long, enabled: true, status: "", count: 0, lastSkipped: nil)
        controller.menuWillOpen(menu)
        controller.setIconPlacement(.beforeActions)
        let iconWidths = try rows.map { try attachmentImage($0).size.width }
        controller.menu(menu, willHighlight: rows[0])
        let oldTimer = timer(in: controller)
        controller.setIconPlacement(.beforeNames)
        try expect(timer(in: controller) == nil && oldTimer?.isValid != true, "Changing placement must stop the old marquee.")
        for index in 0..<3 {
            try expect(rows[index].attributedTitle?.string == prefixes[index] + "\u{fffc}\u{fffc}\u{fffc}", "Long inline-icon titles need separator, icon, then metadata attachments.")
            try expect(abs(try attachmentImage(rows[index]).size.width - iconWidths[index]) < 0.01, "Both visible-icon positions must reserve the same 22 pt and keep metadata aligned.")
            try expect(try attributedTitle(rows[index]).size().width <= 300.5, "Inline icons exceeded the 300 pt title budget.")
        }
        controller.setIconPlacement(.hidden)
        try expect(try rows.map { try attachmentImage($0).size.width } == iconWidths.map { $0 + 22 }, "Hiding icons must restore exactly 22 pt to the metadata viewport.")
        controller.menuDidClose(menu)
        try expect(timer(in: controller) == nil, "Icon transition checks left a marquee timer running.")
    }

    func preemptiveOptionsChecks() throws {
        let controller = StatusMenuController()
        let settings = controller.menu.item(at: 6)!.submenu!
        let preemptive = settings.items.first { $0.action.map(NSStringFromSelector) == "togglePreemptive" }!
        let permission = settings.items.first { $0.action.map(NSStringFromSelector) == "openAccessibilitySettings" }!
        let status = settings.items.first { $0.identifier?.rawValue == "musicFilter.preemptiveStatus" }!
        let firstSeparator = settings.items.firstIndex(where: \.isSeparatorItem)!
        let topActions = settings.items[..<firstSeparator].compactMap { $0.action.map(NSStringFromSelector) }
        try expect(topActions == ["toggleFilter", "togglePreemptive", "openAccessibilitySettings"], "The top settings group must contain only automatic filtering, experimental filtering and its conditional permission action.")
        try expect(preemptive.title == L("Filter upcoming songs (experimental)", "Filtrage anticipé (expérimental)"), "The experimental label is missing or incorrect.")
        try expect(permission.title == L("Allow Accessibility…", "Autoriser l’accessibilité…"), "The Accessibility action is not clear.")
        try expect(permission.image != nil && permission.image?.isTemplate == false, "Accessibility permission needs its colored native warning icon.")
        try expect((permission.image?.size.width ?? 100) <= 14 && (permission.image?.size.height ?? 100) <= 14, "The permission icon must fit within 14 pt.")
        try expect(preemptive.state == .off && permission.isHidden && status.isHidden, "Experimental filtering must start off with no permission prompt or status.")
        try expect(!status.isEnabled && status.action == nil && status.view != nil, "Experimental status must be a disabled descriptive row.")
        try expect(settings.items.allSatisfy { $0.toolTip == nil }, "Settings must not introduce tooltips.")

        controller.setPreemptiveOptions(enabled: false, needsPermission: true, status: "Do not show while off")
        try expect(preemptive.state == .off && permission.isHidden && status.isHidden, "A disabled experiment must never show its permission or status row.")
        let waiting = L("Allow Accessibility to filter the queue.", "Autorise l’accessibilité pour filtrer la file.")
        controller.setPreemptiveOptions(enabled: true, needsPermission: true, status: "  " + waiting + "\n")
        try expect(preemptive.state == .mixed && !permission.isHidden && status.isHidden, "An enabled experiment awaiting permission must show mixed state and only its permission action.")
        try expect(status.accessibilityLabel() == nil, "Awaiting permission must not repeat a disabled status instruction.")
        let label = status.view?.subviews.compactMap { $0 as? NSTextField }.first
        try expect(label?.stringValue.isEmpty == true, "A stale permission instruction must be cleared from the hidden status row.")
        try expect(label?.maximumNumberOfLines == 4, "Experimental status should fit the queue instruction without widening the menu.")

        let queueHint = L("Keep the Music window open (not minimized), even in the background, with the queue displayed.",
                          "Vous devez garder la fenêtre de Musique ouverte (non réduite), même en arrière-plan, avec la file d’attente affichée.")
        controller.setPreemptiveOptions(enabled: true, needsPermission: false, status: queueHint)
        try expect(preemptive.state == .on && permission.isHidden && !status.isHidden && label?.stringValue == queueHint, "Trusted state should show an on checkmark, hide the permission action and display only the queue hint.")
        let shortStatus = L("Waiting for Music.", "En attente de Musique.")
        controller.setPreemptiveOptions(enabled: true, needsPermission: false, status: shortStatus)
        guard let statusView = status.view, let label else {
            throw CheckFailure(message: "Experimental status is missing its view or text field.")
        }
        let shortHeight = statusView.frame.height
        try expect(shortHeight > 0 && statusView.bounds.contains(label.frame), "Short experimental status must fit wholly inside its compact row.")
        try expect(shortHeight == ceil(label.fittingSize.height) + 8, "Short status must reserve only its actual native text height and four-point top/bottom padding.")
        let longStatus = queueHint + "\n" + L("Regular skipping remains active while the queue is unavailable.", "Le saut habituel reste actif pendant que la file est indisponible.")
        controller.menuWillOpen(settings)
        controller.setPreemptiveOptions(enabled: true, needsPermission: false, status: longStatus)
        try expect(statusView.frame.height == shortHeight && label.stringValue == shortStatus && status.accessibilityLabel() == shortStatus, "A live longer status must leave the tracked row and its accessible text stable until the next visit.")
        controller.menuDidClose(settings)
        controller.menuWillOpen(settings)
        let longHeight = statusView.frame.height
        try expect(longHeight > shortHeight && label.stringValue == longStatus && statusView.bounds.contains(label.frame), "The next visit must show the latest status at its natural larger height.")
        try expect(longHeight == ceil(label.fittingSize.height) + 8 && label.frame.height >= ceil(label.fittingSize.height), "Native text height must include the cell allowance without reserving unused lines.")
        controller.setPreemptiveOptions(enabled: true, needsPermission: false, status: shortStatus)
        try expect(statusView.frame.height == longHeight && label.stringValue == longStatus, "A shorter live status must not move the menu rows during tracking.")
        controller.menuDidClose(settings)
        controller.menuWillOpen(settings)
        try expect(statusView.frame.height == shortHeight && label.stringValue == shortStatus, "Reopening a shorter status must remove its unused line space.")
        controller.setPreemptiveOptions(enabled: true, needsPermission: false, status: " \n")
        try expect(!status.isHidden && label.stringValue == shortStatus, "A live empty status must not remove the tracked row beneath the pointer.")
        controller.menuDidClose(settings)
        controller.menuWillOpen(settings)
        try expect(status.isHidden && status.accessibilityLabel() == nil, "An empty experimental status must hide the row and clear stale accessibility text.")
        controller.setPreemptiveOptions(enabled: true, needsPermission: true, status: "")
        try expect(permission.isHidden && preemptive.state == .on, "Permission rows must not appear midway through a settings visit.")
        controller.menuDidClose(settings)
        controller.menuWillOpen(settings)
        try expect(!permission.isHidden && status.isHidden, "Permission visibility must not depend on a nonempty status.")
        controller.menuDidClose(settings)

        let automaticStatus = settings.item(at: 1)!
        let automaticLabel = automaticStatus.view!.subviews.compactMap { $0 as? NSTextField }.first!
        controller.update(track: nil, enabled: true, status: shortStatus, count: 0, lastSkipped: nil)
        controller.menuWillOpen(settings)
        let automaticHeight = automaticStatus.view!.frame.height
        controller.update(track: nil, enabled: true, status: longStatus, count: 0, lastSkipped: nil)
        try expect(automaticLabel.stringValue == shortStatus && automaticStatus.view!.frame.height == automaticHeight, "Automatic-filter descriptions must also remain stable during tracking.")
        controller.menuDidClose(settings)
        controller.menuWillOpen(settings)
        try expect(automaticLabel.stringValue == longStatus && automaticStatus.view!.frame.height > automaticHeight, "Automatic-filter descriptions must refresh with their latest natural height on reopening.")
        controller.menuDidClose(settings)

        var actions: [String] = []
        controller.onTogglePreemptive = { actions.append("preemptive") }
        controller.onOpenAccessibilitySettings = { actions.append("accessibility") }
        settings.performActionForItem(at: settings.index(of: preemptive))
        settings.performActionForItem(at: settings.index(of: permission))
        try expect(actions == ["preemptive", "accessibility"], "Experimental callbacks are incorrectly connected.")
        try expect(preemptive.state == .mixed && !permission.isHidden, "Menu callbacks must not themselves claim a changed preference or granted permission.")
        controller.setPreemptiveOptions(enabled: false, needsPermission: false, status: "Stale error")
        try expect(preemptive.state == .off && permission.isHidden && status.isHidden, "Disabling the experiment did not reset its presentation.")
        try expect(settings.items.allSatisfy { $0.toolTip == nil }, "Experimental state changes introduced tooltips.")
    }

    func writeOffscreenPreview() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            print("Offscreen animation preview skipped because Reduce Motion is enabled.")
            return
        }
        let controller = StatusMenuController()
        let name = "Ballade au clair de lune — édition complète"
        controller.update(track: TrackSnapshot(id: "preview", title: name, artist: "Preview artist", album: "Preview album", isPlaying: true), enabled: true, status: "", count: 0, lastSkipped: nil)
        let row = controller.menu.item(at: 0)!
        controller.menuWillOpen(controller.menu)
        controller.menu(controller.menu, willHighlight: row)
        let viewport = try attachmentImage(row).size.width
        let duration = max(0, (measure(name) - viewport) / 24)
        let times = [0.0, 1 + duration / 2, 1 + duration + 0.12]
        var frames: [NSAttributedString] = []
        var previous = 0.0
        for time in times {
            pumpRunLoop(for: max(0, time - previous))
            frames.append(try attributedTitle(row).copy() as! NSAttributedString)
            previous = time
        }
        controller.menuDidClose(controller.menu)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 720, height: 250)
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 720, height: 250))
        for (column, appearanceName) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let appearance = NSAppearance(named: appearanceName)!
            appearance.performAsCurrentDrawingAppearance {
                let x = CGFloat(column) * 360
                NSColor.windowBackgroundColor.setFill(); NSRect(x: x, y: 0, width: 360, height: 250).fill()
                let heading = column == 0 ? "Clair — aperçu hors écran" : "Sombre — aperçu hors écran"
                (heading as NSString).draw(at: NSPoint(x: x + 14, y: 220), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
                for (index, frame) in frames.enumerated() {
                    let y = 165 - CGFloat(index) * 60
                    (["Début", "Milieu", "Fin"][index] as NSString).draw(at: NSPoint(x: x + 14, y: y + 28), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
                    NSColor.selectedContentBackgroundColor.setFill(); NSBezierPath(roundedRect: NSRect(x: x + 8, y: y, width: 344, height: 24), xRadius: 4, yRadius: 4).fill()
                    let title = NSMutableAttributedString(attributedString: frame)
                    title.addAttribute(.foregroundColor, value: NSColor.selectedMenuItemTextColor, range: NSRange(location: 0, length: title.length))
                    title.draw(at: NSPoint(x: x + 20, y: y + 4))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let path = URL(fileURLWithPath: "/tmp/music-filter-menu-marquee-preview.png")
        try rep.representation(using: .png, properties: [:])!.write(to: path)
        print("Offscreen preview: \(path.path)")
        try expect(timer(in: controller) == nil, "Preview generation left a timer running.")
    }

    private func clean(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private func measure(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    private func attributedTitle(_ item: NSMenuItem) throws -> NSAttributedString {
        guard let title = item.attributedTitle else { throw CheckFailure(message: "Expected an attributed overflow title.") }
        return title
    }
    private func attachmentImage(_ item: NSMenuItem) throws -> NSImage {
        let title = try attributedTitle(item)
        guard title.length > 0, let attachment = title.attribute(.attachment, at: title.length - 1, effectiveRange: nil) as? NSTextAttachment, let image = attachment.image else {
            throw CheckFailure(message: "Overflow title is missing its image attachment.")
        }
        return image
    }
    private func rasterData(_ image: NSImage) throws -> Data {
        guard let data = image.tiffRepresentation else { throw CheckFailure(message: "Could not rasterize the attachment.") }
        return data
    }
    private func timer(in controller: StatusMenuController) -> Timer? {
        Mirror(reflecting: controller).children.first(where: { $0.label == "marqueeTimer" })?.value as? Timer
    }
    private func pumpRunLoop(for duration: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.02)))
        }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { "Menu check failed: \(message)" }
}
