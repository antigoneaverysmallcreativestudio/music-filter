import AppKit

#if canImport(FiltreCore)
import FiltreCore
#endif

enum MenuBarIcon: String {
    case musicHand7 = "music.hand7"

    func image(in bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(forResource: rawValue, withExtension: "pdf", subdirectory: "MenuBarIcons"),
              let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(18 / image.size.height, 20 / image.size.width)
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.isTemplate = true
        image.accessibilityDescription = "Music Filter"
        return image
    }
}

enum MenuIconPlacement: String, CaseIterable {
    case beforeActions, beforeNames, hidden

    var title: String {
        switch self {
        case .beforeActions: return L("Before actions", "Devant \"Exclure\"")
        case .beforeNames: return L("Before names", "Devant les noms")
        case .hidden: return L("No icons", "Sans icônes")
        }
    }
}

/// One album outline and a centered native person, shared by every album UI.
@MainActor
enum AlbumIcon {
    static func image(side: CGFloat, color: NSColor? = nil,
                      showsExclusionBadge: Bool = false) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
        guard side > 0,
              let person = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration),
              person.size.width > 0, person.size.height > 0 else { return nil }
        let scale = min(16 / person.size.width, 16 / person.size.height)
        let personSize = NSSize(width: person.size.width * scale, height: person.size.height * scale)
        let personRect = NSRect(x: 12 - personSize.width / 2, y: 12 - personSize.height / 2,
                                width: personSize.width, height: personSize.height)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: bounds.width / 24, y: bounds.height / 24)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 21, height: 21),
                                       xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.5
            outline.stroke()
            person.draw(in: personRect)
            if showsExclusionBadge {
                let center = NSPoint(x: 17.6, y: 7)
                // Clear the halo and minus from the template mask, so they
                // remain transparent under white, blue or disabled tinting.
                context.setBlendMode(.clear)
                NSBezierPath(ovalIn: NSRect(x: center.x - 4.2, y: center.y - 4.2,
                                           width: 8.4, height: 8.4)).fill()
                context.setBlendMode(.normal)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 3.4, y: center.y - 3.4,
                                           width: 6.8, height: 6.8)).fill()
                context.setBlendMode(.clear)
                NSBezierPath(roundedRect: NSRect(x: center.x - 1.3, y: center.y - 0.5,
                                                width: 2.6, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
                context.setBlendMode(.normal)
            }
            if let color {
                context.setBlendMode(.sourceIn)
                color.setFill()
                NSRect(x: 0, y: 0, width: 24, height: 24).fill()
            }
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

enum RedDotPosition: String, CaseIterable {
    case upperRight, onHand, lowerRight

    var title: String {
        switch self {
        case .upperRight: return L("Upper right", "En haut à droite")
        case .onHand: return L("On the hand", "Sur la main")
        case .lowerRight: return L("Lower right", "En bas à droite")
        }
    }
}

/// A separate colored overlay keeps the existing icon a native template image.
@MainActor
final class StatusActivityIndicator {
    private let dot: ActivityDotView
    private var hideTimer: Timer?
    private var generation: UInt64 = 0

    init(button: NSButton) {
        dot = ActivityDotView(frame: button.bounds)
        dot.button = button
        dot.autoresizingMask = [.width, .height]
        dot.identifier = NSUserInterfaceItemIdentifier("musicFilter.activityDot")
        dot.setAccessibilityElement(false)
        dot.isHidden = true
        button.addSubview(dot)
    }

    func pulse() {
        show(for: 10)
    }

    func setPosition(_ position: RedDotPosition) {
        dot.position = position
        dot.needsDisplay = true
    }

    private func show(for duration: TimeInterval) {
        hideTimer?.invalidate()
        generation &+= 1
        let currentGeneration = generation
        dot.isHidden = false
        dot.needsDisplay = true
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == currentGeneration else { return }
                self.reset()
            }
        }
        hideTimer = timer
        // The indicator also expires while a status menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
    }

    func reset() {
        generation &+= 1
        hideTimer?.invalidate()
        hideTimer = nil
        dot.isHidden = true
    }

    private final class ActivityDotView: NSView {
        weak var button: NSButton?
        var position: RedDotPosition = .upperRight
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let button, let cell = button.cell else { return }
            let icon = convert(cell.imageRect(forBounds: button.bounds), from: button)
            let diameter: CGFloat = 5
            let scale = window?.backingScaleFactor ?? 2
            let origin: NSPoint
            switch position {
            case .upperRight:
                origin = NSPoint(x: icon.maxX - diameter / 2 + 3, y: icon.minY + 2)
            case .onHand:
                origin = NSPoint(x: icon.minX + icon.width * 0.79 - diameter / 2,
                                 y: icon.minY + icon.height * 0.82 - diameter / 2)
            case .lowerRight:
                origin = NSPoint(x: icon.maxX - diameter / 2 + 3, y: icon.maxY - diameter + 2)
            }
            let x = min(bounds.maxX - diameter - 0.5, origin.x)
            let y = min(bounds.maxY - diameter - 1, origin.y)
            let rect = NSRect(x: (max(bounds.minX + 1, x) * scale).rounded() / scale,
                              y: (max(bounds.minY + 1, y) * scale).rounded() / scale,
                              width: diameter, height: diameter)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

/// Presents the existing native menus without NSStatusItem.menu's automatic
/// activation handoff, which can briefly cover an accessory app's open windows.
@MainActor
final class StatusMenuPresenter: NSObject {
    private weak var button: NSButton?
    private weak var statusItem: NSStatusItem?
    private let primaryMenu: NSMenu
    private let recentMenu: NSMenu
    private let onWillPresent: (() -> Void)?
    private weak var previousTarget: AnyObject?
    private let previousAction: Selector?
    private let previousActionMask: NSEvent.EventTypeMask
    private var secondaryClickMonitor: Any?
    private var trackingMenu: NSMenu?
    // Kept type-erased so the legacy presenter remains available before 27.
    private var expandedSession: AnyObject?
    private var trackingExpandedSession: AnyObject?
    private var afterTrackingActions: [() -> Void] = []
    private var invalidated = false

    init(button: NSButton, primaryMenu: NSMenu, recentMenu: NSMenu,
         statusItem: NSStatusItem? = nil,
         onWillPresent: (() -> Void)? = nil) {
        self.button = button
        self.statusItem = statusItem
        self.primaryMenu = primaryMenu
        self.recentMenu = recentMenu
        self.onWillPresent = onWillPresent
        previousTarget = button.target
        previousAction = button.action
        previousActionMask = NSEvent.EventTypeMask(rawValue: UInt64(bitPattern:
            Int64(button.sendAction(on: .leftMouseDown))))
        super.init()
        if #available(macOS 27.0, *), let statusItem {
            // macOS 27 manages the menu-bar capsule outside the button's
            // pressed drawing. A native expanded session keeps it selected
            // until our manually presented menu has actually closed.
            button.target = nil
            button.action = nil
            statusItem.expandedInterfaceDelegate = self
        } else {
            button.target = self
            button.action = #selector(buttonPressed(_:))
        }
        // Ordinary NSButton cells do not preserve a right-mouse-down action
        // mask. Handle only secondary clicks on this exact button locally.
        secondaryClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, !self.invalidated, self.trackingMenu == nil,
                      self.isSecondaryClickOnButton(event) else { return false }
                self.presentMenu(for: event)
                return true
            }
            return handled ? nil : event
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard sender === button else { return }
        presentMenu(for: NSApp.currentEvent)
    }

    @discardableResult
    func presentPrimaryMenu() -> Bool {
        present(primaryMenu)
    }

    func performAfterTracking(_ action: @escaping () -> Void) {
        guard !invalidated else { return }
        if trackingMenu == nil && expandedSession == nil { action() }
        else { afterTrackingActions.append(action) }
    }

    private func finishTrackingActionsIfPossible() {
        guard !invalidated, trackingMenu == nil, expandedSession == nil else { return }
        let actions = afterTrackingActions
        afterTrackingActions.removeAll()
        for action in actions {
            guard !invalidated else { break }
            action()
        }
    }

    @discardableResult
    func presentMenu(for event: NSEvent?) -> Bool {
        let secondary = event?.type == .rightMouseDown ||
            (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        return present(secondary ? recentMenu : primaryMenu)
    }

    func isSecondaryClickOnButton(_ event: NSEvent) -> Bool {
        guard event.type == .rightMouseDown ||
                (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              let button, button.isEnabled, let window = button.window,
              event.window === window else { return false }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    private func present(_ menu: NSMenu, nativeSession: AnyObject? = nil,
                         endExpandedSession: (() -> Void)? = nil) -> Bool {
        guard !invalidated, trackingMenu == nil, let button,
              button.window != nil, button.isEnabled,
              expandedSession == nil || expandedSession === nativeSession else { return false }
        trackingMenu = menu
        trackingExpandedSession = nativeSession
        // Retain button-state rendering for the legacy/manual presentation
        // path. On macOS 27, the expanded session owns the primary menu's
        // system capsule; pressed state alone does not keep that capsule open.
        let previousState = button.state
        let cell = button.cell as? NSButtonCell
        let previousShowsStateBy = cell?.showsStateBy
        cell?.showsStateBy = .changeBackgroundCellMask
        button.state = .on
        button.highlight(true)
        defer {
            button.state = previousState
            if let previousShowsStateBy { cell?.showsStateBy = previousShowsStateBy }
            button.highlight(false)
            trackingMenu = nil
            trackingExpandedSession = nil
            // End the native session before an explicit window command can
            // activate the app, preserving the existing post-menu ordering.
            endExpandedSession?()
            // Native tracking can restore focus and ordering when popUp ends.
            // Explicit window commands run only after that call has returned.
            // cancel() may deliver didEnd later. Both native-session dismissal
            // and the synchronous popup must finish before recalling a window.
            finishTrackingActionsIfPossible()
        }
        onWillPresent?()
        // The callback can invalidate the presenter while preparing its windows.
        guard !invalidated, button.window != nil, button.isEnabled else { return false }
        let lowerEdge = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        // Visual alignment with the expanded capsule on macOS 27: its leading
        // edge extends 10 points beyond the button. Only the primary panel
        // attached to that capsule receives this horizontal adjustment.
        let expandedCapsuleLeadingOutset: CGFloat = 10
        let leadingEdge = button.bounds.minX -
            (menu === primaryMenu && nativeSession != nil ? expandedCapsuleLeadingOutset : 0)
        return menu.popUp(positioning: nil,
                          at: NSPoint(x: leadingEdge, y: lowerEdge), in: button)
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        afterTrackingActions.removeAll()
        if let secondaryClickMonitor { NSEvent.removeMonitor(secondaryClickMonitor) }
        secondaryClickMonitor = nil
        trackingMenu?.cancelTracking()
        if #available(macOS 27.0, *), let statusItem,
           statusItem.expandedInterfaceDelegate === self {
            statusItem.expandedInterfaceSession?.cancel()
            statusItem.expandedInterfaceDelegate = nil
            if let button, button.target == nil, button.action == nil {
                button.target = previousTarget
                button.action = previousAction
                button.sendAction(on: previousActionMask)
            }
        }
        expandedSession = nil
        trackingExpandedSession = nil
        // Do not overwrite a target/action installed by another owner meanwhile.
        if let button, button.target === self, button.action == #selector(buttonPressed(_:)) {
            button.target = previousTarget
            button.action = previousAction
            button.sendAction(on: previousActionMask)
        }
    }

    deinit {
        if let secondaryClickMonitor { NSEvent.removeMonitor(secondaryClickMonitor) }
    }
}

@available(macOS 27.0, *)
extension StatusMenuPresenter: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        guard !invalidated, statusItem === self.statusItem, expandedSession == nil else {
            session.cancel()
            return
        }
        expandedSession = session
        // Return to AppKit first so it can commit the expanded menu-bar state
        // before NSMenu enters its synchronous tracking loop.
        DispatchQueue.main.async { [weak self, weak statusItem] in
            guard let self, !self.invalidated, let statusItem,
                  self.expandedSession === session,
                  statusItem.expandedInterfaceSession === session else { return }
            var cancellationRequested = false
            let cancelSession = {
                guard !cancellationRequested, statusItem.expandedInterfaceSession === session else { return }
                cancellationRequested = true
                session.cancel()
            }
            _ = self.present(self.primaryMenu, nativeSession: session, endExpandedSession: cancelSession)
            // Also balance a session when presentation was rejected early.
            cancelSession()
        }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        guard statusItem === self.statusItem,
              statusItem.expandedInterfaceSession == nil,
              let endedSession = expandedSession else { return }
        expandedSession = nil
        // An ended native session must never dismiss a manually opened recent
        // menu, or a popup owned by a different session.
        if trackingExpandedSession === endedSession { trackingMenu?.cancelTracking() }
        // AppKit may still restore focus after this callback. An asynchronous
        // didEnd must return before an explicit command brings a window forward.
        DispatchQueue.main.async { [weak self] in self?.finishTrackingActionsIfPossible() }
    }
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let recentExclusionMenu = NSMenu()
    var onWillPresent: (() -> Void)?
    var onRecentExclusionMenuWillOpen: (() -> String?)?

    var onBanArtist: ((TrackSnapshot) -> Void)?
    var onBanAlbum: ((TrackSnapshot) -> Void)?
    var onBanTrack: ((TrackSnapshot) -> Void)?
    var onToggle: (() -> Void)?
    var onManage: (() -> Void)?
    var onAbout: (() -> Void)?
    var onTogglePreemptive: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onToggleFollowMusic: (() -> Void)?
    var onOpenLoginSettings: (() -> Void)?
    var onWillOpen: (() -> Void)?
    var onQuit: (() -> Void)?

    private let recentSongItem = AccessibleMenuItem()
    private var recentSongName = ""
    private var isRecentTracking = false
    private var recentSongAction: String {
        recentSongName.isEmpty ? L("No recent automatic exclusions", "Aucune exclusion automatique récente")
            : L("Recently excluded song", "Morceau exclu récemment")
    }
    private let banArtistItem = AccessibleMenuItem()
    private let banAlbumItem = AccessibleMenuItem()
    private let banTrackItem = AccessibleMenuItem()
    private let filteringItem = AccessibleMenuItem()
    private let manageItem = AccessibleMenuItem()
    private let preemptiveItem = AccessibleMenuItem()
    private let accessibilityApprovalItem = AccessibleMenuItem()
    private let preemptiveStatusItem = NSMenuItem()
    private let preemptiveStatusView = MenuTextRow(text: "", maximumLines: 4)
    private let followMusicItem = AccessibleMenuItem()
    private let loginApprovalItem = AccessibleMenuItem()
    private let statusItem = NSMenuItem()
    private let settingsItem = AccessibleMenuItem()
    private let statusView = MenuTextRow(text: "", maximumLines: 0)
    private var pendingTrack: TrackSnapshot?
    private var interactionTrack: TrackSnapshot?
    private var displayedTrack: TrackSnapshot?
    private var isTracking = false
    private var isSettingsTracking = false
    private var pendingStatusText = ""
    private var pendingPreemptiveOptions: (enabled: Bool, needsPermission: Bool, status: String)?
    private var artistName = ""
    private var albumName = ""
    private var songName = ""
    private var highlightedAction: NSMenuItem?
    private var marqueeTimer: Timer?
    private var marqueeStart = 0.0
    private struct NameRendering: Equatable {
        let name: String
        let offset: CGFloat
        let highlighted: Bool
        let enabled: Bool
    }
    private var renderedNames: [ObjectIdentifier: NameRendering] = [:]
    private var measuredMenuWidths: [ObjectIdentifier: CGFloat] = [:]
    private let artistAction = L("Exclude artist", "Exclure l’artiste")
    private let albumAction = L("Exclude album", "Exclure l’album")
    private let songAction = L("Exclude song", "Exclure le morceau")
    private let menuFont = NSFont.menuFont(ofSize: 0)
    private let titleWidth: CGFloat = 300
    private var iconPlacement: MenuIconPlacement = .beforeActions
    private var rowIcons: [ObjectIdentifier: NSImage] = [:]
    private var standardRowIcons: [ObjectIdentifier: NSImage] = [:]
    private var exclusionIconBadgesEnabled = false
    private let inlineIconWidth: CGFloat = 22
    private let separatorLeadingGap: CGFloat = 12
    private let separatorTrailingGap: CGFloat = 14

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self

        configure(banArtistItem, title: artistAction, action: #selector(banArtist), symbol: "music.mic")
        configure(banAlbumItem, title: albumAction, action: #selector(banAlbum))
        banAlbumItem.image = albumIcon()
        configure(banTrackItem, title: songAction, action: #selector(banTrack), symbol: "music.note")
        for item in [banTrackItem, banAlbumItem, banArtistItem] {
            rowIcons[ObjectIdentifier(item)] = item.image
            standardRowIcons[ObjectIdentifier(item)] = item.image
            // This menu style can omit NSMenuItem.image when an attributed
            // title is present. Both placements use visible inline artwork.
            item.image = nil
        }
        menu.addItem(banTrackItem)
        menu.addItem(banAlbumItem)
        menu.addItem(banArtistItem)
        menu.addItem(.separator())
        configure(manageItem, title: "", action: #selector(manage))
        menu.addItem(manageItem)
        menu.addItem(.separator())

        configure(settingsItem, title: L("Settings", "Réglages"), action: nil)
        let settings = NSMenu()
        settings.minimumWidth = 260
        settings.autoenablesItems = false
        settings.delegate = self
        configure(filteringItem, title: L("Automatic filtering", "Filtrage automatique"), action: #selector(toggleFilter))
        settings.addItem(filteringItem)
        statusItem.isEnabled = false
        statusItem.view = statusView
        statusItem.isHidden = true
        settings.addItem(statusItem)
        configure(preemptiveItem, title: L("Filter upcoming songs (experimental)", "Filtrage anticipé (expérimental)"), action: #selector(togglePreemptive))
        settings.addItem(preemptiveItem)
        configure(accessibilityApprovalItem, title: L("Allow Accessibility…", "Autoriser l’accessibilité…"), action: #selector(openAccessibilitySettings))
        let permissionImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                      accessibilityDescription: L("Permission required", "Autorisation nécessaire"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemYellow])))
        if let permissionImage, permissionImage.size.width > 0, permissionImage.size.height > 0 {
            let scale = min(14 / permissionImage.size.width, 14 / permissionImage.size.height)
            permissionImage.size = NSSize(width: permissionImage.size.width * scale,
                                          height: permissionImage.size.height * scale)
            permissionImage.isTemplate = false
        }
        accessibilityApprovalItem.image = permissionImage
        accessibilityApprovalItem.isHidden = true
        settings.addItem(accessibilityApprovalItem)
        preemptiveStatusItem.identifier = NSUserInterfaceItemIdentifier("musicFilter.preemptiveStatus")
        preemptiveStatusItem.isEnabled = false
        preemptiveStatusItem.view = preemptiveStatusView
        preemptiveStatusItem.isHidden = true
        settings.addItem(preemptiveStatusItem)
        settings.addItem(.separator())
        configure(followMusicItem, title: L("Start with Music", "Démarrer avec Musique"), action: #selector(toggleFollowMusic))
        configure(loginApprovalItem, title: L("Allow in System Settings…", "Autoriser dans Réglages Système…"), action: #selector(openLoginSettings))
        loginApprovalItem.isHidden = true
        settings.addItem(followMusicItem)
        settings.addItem(loginApprovalItem)
        settingsItem.submenu = settings
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(item(title: L("About Music Filter", "À propos de Music Filter"), action: #selector(about)))
        menu.addItem(item(title: L("Quit Music Filter", "Quitter Music Filter"), action: #selector(quit)))

        let customRows: [(NSMenuItem, MenuActionRow.Tint, CGFloat, CGFloat)] = [
            (banTrackItem, .blue, 11, 11), (banAlbumItem, .blue, 11, 11),
            (banArtistItem, .blue, 11, 11), (manageItem, .neutral, 11, 11),
            (settingsItem, .neutral, 11, 11), (menu.items[8], .neutral, 11, 11),
            (menu.items[9], .neutral, 11, 11)
        ]
        for (index, entry) in customRows.enumerated() {
            let row = MenuActionRow(tint: entry.1, topRadius: entry.2, bottomRadius: entry.3)
            row.identifier = NSUserInterfaceItemIdentifier("musicFilter.menuRow.\(index)")
            entry.0.view = row
        }

        for item in [filteringItem, preemptiveItem, accessibilityApprovalItem, followMusicItem, loginApprovalItem] {
            item.view = MenuActionRow(tint: .neutral, topRadius: 11, bottomRadius: 11, showsStateColumn: true)
        }
        recentExclusionMenu.autoenablesItems = false
        recentExclusionMenu.delegate = self
        configure(recentSongItem, title: recentSongAction, action: nil)
        recentSongItem.view = MenuActionRow(tint: .informational, topRadius: 11, bottomRadius: 11)
        recentSongItem.view?.identifier = NSUserInterfaceItemIdentifier("musicFilter.recentExcludedSong")
        recentSongItem.isEnabled = false
        refreshRecentSongIcon()
        recentExclusionMenu.addItem(recentSongItem)
        refreshSettingsRows()

        displayTrack(nil, force: true)
        update(track: nil, enabled: true, status: "", count: 0, lastSkipped: nil)
        setPreemptiveOptions(enabled: false, needsPermission: false, status: "")
    }

    func setIconPlacement(_ placement: MenuIconPlacement) {
        guard iconPlacement != placement else { return }
        iconPlacement = placement
        stopMarquee()
        highlightedAction = nil
        renderedNames.removeAll()
        renderTitles()
    }

    func setStartupOptions(launchAtLogin _: Bool, needsApproval: Bool, followMusic: Bool) {
        // Login-item registration is an implementation detail of following
        // Music; the menu exposes only the user's "Start with Music" choice.
        followMusicItem.state = needsApproval ? .mixed : (followMusic ? .on : .off)
        loginApprovalItem.isHidden = !needsApproval
        refreshSettingsRows()
    }

    func setExclusionIconBadgesEnabled(_ enabled: Bool) {
        guard exclusionIconBadgesEnabled != enabled else { return }
        exclusionIconBadgesEnabled = enabled
        for (item, resource) in [(banTrackItem, "exclude-song"), (banAlbumItem, "exclude-album"),
                                 (banArtistItem, "exclude-artist")] {
            let key = ObjectIdentifier(item)
            rowIcons[key] = enabled ? (exclusionIcon(named: resource) ?? standardRowIcons[key]) : standardRowIcons[key]
        }
        refreshRecentSongIcon()
        stopMarquee()
        highlightedAction = nil
        renderedNames.removeAll()
        renderTitles()
    }

    func setPreemptiveOptions(enabled: Bool, needsPermission: Bool, status: String) {
        pendingPreemptiveOptions = (enabled, needsPermission, status)
        // Native menu tracking retains each custom row's opening height. Keep
        // its text and visibility together until the next settings visit.
        guard !isSettingsTracking else { return }
        applyPreemptiveOptions(enabled: enabled, needsPermission: needsPermission, status: status)
    }

    private func applyPreemptiveOptions(enabled: Bool, needsPermission: Bool, status: String) {
        preemptiveItem.state = !enabled ? .off : (needsPermission ? .mixed : .on)
        accessibilityApprovalItem.isHidden = !enabled || !needsPermission
        // The permission row already explains what is needed. Do not repeat
        // that instruction in a second disabled row, even for stale callers.
        let message = needsPermission ? "" : status.trimmingCharacters(in: .whitespacesAndNewlines)
        preemptiveStatusItem.isHidden = !enabled || message.isEmpty
        if preemptiveStatusView.text != message { preemptiveStatusView.setText(message) }
        preemptiveStatusItem.setAccessibilityLabel(message.isEmpty ? nil : message)
        refreshSettingsRows()
    }

    func update(track: TrackSnapshot?, enabled: Bool, status: String, count: Int, lastSkipped: String?) {
        filteringItem.state = enabled ? .on : .off
        let manageTitle = L("Manage exclusions", "Gérer les exclusions") + " (\(count))"
        if manageItem.title != manageTitle {
            manageItem.title = manageTitle
            manageItem.view?.needsDisplay = true
            fitMenuRows()
        }

        pendingTrack = track
        // Keep both the names and their actions stable during one menu visit.
        // Playback and filtering keep following the actual current song.
        if !isTracking && !isRecentTracking { displayTrack(track) }

        pendingStatusText = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isSettingsTracking { applyStatusText() }
        refreshSettingsRows()
    }

    private func applyStatusText() {
        let message = pendingStatusText
        statusItem.isHidden = message.isEmpty
        if statusView.text != message { statusView.setText(message) }
    }

    private func displayTrack(_ track: TrackSnapshot?, force: Bool = false) {
        guard force || displayedTrack != track else { return }
        displayedTrack = track
        artistName = clean(track?.artist)
        albumName = clean(track?.album)
        songName = clean(track?.title)
        banArtistItem.isEnabled = !artistName.isEmpty
        banAlbumItem.isEnabled = !albumName.isEmpty && !clean(track?.albumIdentityArtist).isEmpty
        banTrackItem.isEnabled = !artistName.isEmpty && !songName.isEmpty
        banArtistItem.setAccessibilityLabel(artistName.isEmpty
            ? L("No artist detected in Music", "Aucun artiste détecté dans Musique")
            : artistAction + " : " + artistName)
        banAlbumItem.setAccessibilityLabel(banAlbumItem.isEnabled
            ? albumAction + " : " + albumName + " · " + clean(track?.albumIdentityArtist)
            : L("No album detected in Music", "Aucun album détecté dans Musique"))
        banTrackItem.setAccessibilityLabel(banTrackItem.isEnabled
            ? songAction + " : " + songName + " · " + artistName
            : L("No song detected in Music", "Aucun morceau détecté dans Musique"))
        renderTitles()
    }

    private func clean(_ value: String?) -> String {
        value?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu || menu === recentExclusionMenu { onWillPresent?() }
        // Start each visit from the content's compact width. AppKit may then
        // expand the views to the native menu width while it lays out the menu.
        measuredMenuWidths.removeValue(forKey: ObjectIdentifier(menu))
        if menu === recentExclusionMenu {
            // Snapshot the last confirmed event for this menu visit, just as
            // the main menu freezes the currently playing song while open.
            recentSongName = clean(onRecentExclusionMenuWillOpen?())
            recentSongItem.isEnabled = false
            (recentSongItem.view as? MenuActionRow)?.informationalContentAvailable = !recentSongName.isEmpty
            refreshRecentSongIcon()
            renderedNames.removeValue(forKey: ObjectIdentifier(recentSongItem))
            recentSongItem.setAccessibilityLabel(recentSongName.isEmpty
                ? L("No recent automatic exclusions", "Aucune exclusion automatique récente")
                : recentSongAction + " : " + recentSongName)
            isRecentTracking = true
            stopMarquee()
            highlightedAction = nil
            renderTitles()
            startMarquee(for: recentSongName.isEmpty ? nil : recentSongItem)
            return
        }
        if menu === settingsItem.submenu {
            applyStatusText()
            if let options = pendingPreemptiveOptions {
                applyPreemptiveOptions(enabled: options.enabled, needsPermission: options.needsPermission, status: options.status)
            }
            isSettingsTracking = true
            refreshSettingsRows()
            return
        }
        if menu !== self.menu { refreshSettingsRows(); return }
        onWillOpen?()
        interactionTrack = pendingTrack
        displayTrack(interactionTrack)
        isTracking = true
        highlightedAction = nil
        renderTitles()
    }

    func menuDidClose(_ menu: NSMenu) {
        for row in menu.items { (row.view as? MenuActionRow)?.highlighted = false }
        if menu === settingsItem.submenu {
            isSettingsTracking = false
            return
        }
        if menu === recentExclusionMenu {
            isRecentTracking = false
            stopMarquee()
            highlightedAction = nil
            renderTitles()
            return
        }
        guard menu === self.menu else { return }
        isTracking = false
        isSettingsTracking = false
        stopMarquee()
        highlightedAction = nil
        renderTitles()
        // AppKit can send the selected action after closing and a later poll.
        // Its target must remain the snapshot the user saw during this visit.
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        // This row is descriptive only: hovering or keyboard navigation must
        // neither select it nor restart its independently running marquee.
        if menu === recentExclusionMenu { return }
        for row in menu.items {
            (row.view as? MenuActionRow)?.highlighted = row === item
        }
        guard menu === self.menu else { return }
        if item === highlightedAction { return }
        stopMarquee()
        highlightedAction = actionRows.contains { $0.item === item } ? item : nil
        renderTitles()
        startMarquee(for: highlightedAction)
    }

    private func startMarquee(for item: NSMenuItem?) {
        guard let item, let row = allNameRows.first(where: { $0.item === item }),
              measure(row.name) > availableWidth(for: row.action),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        marqueeStart = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: item === recentSongItem ? 1 / 60 : 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceMarquee() }
        }
        marqueeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private var actionRows: [(item: NSMenuItem, action: String, name: String)] {
        [(banTrackItem, songAction, songName), (banAlbumItem, albumAction, albumName),
         (banArtistItem, artistAction, artistName)]
    }

    private var allNameRows: [(item: NSMenuItem, action: String, name: String)] {
        actionRows + [(recentSongItem, recentSongAction, recentSongName)]
    }

    private func refreshRecentSongIcon() {
        let key = ObjectIdentifier(recentSongItem)
        if recentSongName.isEmpty { rowIcons.removeValue(forKey: key) }
        else { rowIcons[key] = rowIcons[ObjectIdentifier(banTrackItem)] }
    }

    private func stopMarquee() {
        marqueeTimer?.invalidate()
        marqueeTimer = nil
    }

    private var marqueeItem: NSMenuItem? {
        isRecentTracking && !recentSongName.isEmpty ? recentSongItem : highlightedAction
    }

    private func advanceMarquee() {
        guard isTracking || isRecentTracking, marqueeItem != nil else { stopMarquee(); return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopMarquee(); renderTitles(); return
        }
        renderTitles()
    }

    private func availableWidth(for action: String) -> CGFloat {
        max(80, titleWidth - metadataLeadingOffset(for: action) - (iconPlacement == .hidden ? 0 : inlineIconWidth))
    }

    private var actionColumnWidth: CGFloat {
        ceil([songAction, albumAction, artistAction].map(measure).max() ?? 0)
    }

    private func columnWidth(for action: String) -> CGFloat {
        action == recentSongAction ? ceil(measure(action)) : actionColumnWidth
    }

    private func metadataLeadingOffset(for action: String) -> CGFloat {
        columnWidth(for: action) + separatorLeadingGap + 1 + separatorTrailingGap
    }

    /// Keep the complete menu title and its inline artwork together.
    /// Only overflowing metadata uses a clipped, scrolling text attachment.
    private func renderTitles() {
        // Every refresh uses the same monotonic animation clock. Playback
        // updates must never insert an elapsed=0 frame between timer ticks.
        let elapsed = marqueeTimer == nil ? 0 : max(0, ProcessInfo.processInfo.systemUptime - marqueeStart)
        defer {
            fitMenuRows()
            fitMenuRows(in: recentExclusionMenu)
            for row in allNameRows { row.item.view?.needsDisplay = true }
        }
        for row in allNameRows {
            let contentEnabled = row.item === recentSongItem ? !recentSongName.isEmpty : row.item.isEnabled
            let selected = row.item !== recentSongItem && row.item === highlightedAction
            guard !row.name.isEmpty else {
                renderedNames.removeValue(forKey: ObjectIdentifier(row.item))
                if iconPlacement == .beforeActions, let icon = rowIcons[ObjectIdentifier(row.item)] {
                    let title = NSMutableAttributedString(attributedString:
                        inlineImage(metadataIcon(icon, highlighted: false, enabled: contentEnabled)))
                    title.append(NSAttributedString(string: row.action, attributes: [.font: menuFont]))
                    row.item.attributedTitle = title
                } else {
                    row.item.attributedTitle = nil
                    row.item.title = row.action
                }
                continue
            }
            let width = availableWidth(for: row.action)
            let fullWidth = measure(row.name)
            let distance = max(0, fullWidth - width)
            let duration = Double(distance / 24)
            let phase = elapsed.truncatingRemainder(dividingBy: duration * 2 + 2)
            let offset: CGFloat
            if row.item !== marqueeItem || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                offset = 0
            } else if phase < 1 {
                offset = 0
            } else if phase < 1 + duration {
                offset = CGFloat(phase - 1) * 24
            } else if phase < 2 + duration {
                offset = distance
            } else {
                offset = max(0, distance - CGFloat(phase - 2 - duration) * 24)
            }
            let key = ObjectIdentifier(row.item)
            let rendering = NameRendering(name: row.name, offset: offset,
                                          highlighted: selected, enabled: contentEnabled)
            guard renderedNames[key] != rendering else { continue }
            renderedNames[key] = rendering
            let title = NSMutableAttributedString(string: "")
            if iconPlacement == .beforeActions, let icon = rowIcons[key] {
                title.append(inlineImage(metadataIcon(icon, highlighted: selected,
                                                     enabled: contentEnabled)))
            }
            title.append(NSAttributedString(string: row.action, attributes: [.font: menuFont]))
            title.append(inlineImage(separatorImage(after: row.action,
                                                    highlighted: selected,
                                                    enabled: contentEnabled)))
            if iconPlacement == .beforeNames, let icon = rowIcons[key] {
                title.append(inlineImage(metadataIcon(icon, highlighted: selected,
                                                     enabled: contentEnabled)))
            }
            if distance > 0 {
                let image = fadingName(row.name, width: width, offset: offset, distance: distance,
                                       highlighted: selected, enabled: contentEnabled)
                title.append(inlineImage(image))
            } else {
                title.append(NSAttributedString(string: row.name, attributes: [.font: menuFont]))
            }
            row.item.attributedTitle = title
        }
    }

    private func refreshSettingsRows() {
        guard let settings = settingsItem.submenu else { return }
        let rows = settings.items.filter { !$0.isHidden && $0.view is MenuActionRow }
        for item in rows {
            guard let row = item.view as? MenuActionRow else { continue }
            row.needsDisplay = true
        }
        fitMenuRows(in: settings)
    }

    private func fitMenuRows(in target: NSMenu? = nil) {
        let target = target ?? menu
        let rows = target.items.filter { !$0.isHidden && $0.view is MenuActionRow }
        let width = ceil(max(target.minimumWidth, rows.map { item in
            (item.view as! MenuActionRow).requiredWidth(for: item)
        }.max() ?? 0))
        guard width > 0 else { return }
        let key = ObjectIdentifier(target)
        let widthChanged = measuredMenuWidths[key] != width
        measuredMenuWidths[key] = width
        let visibleItems = target.items.filter { !$0.isHidden }
        for item in target.items {
            guard let row = item.view as? MenuActionRow else { continue }
            // AppKit contributes five points at the menu edges. These two
            // extra points match the seven-point side margins without
            // changing the native 24-point selection or spacing between rows.
            row.topPadding = item === visibleItems.first ? 2 : 0
            row.bottomPadding = item === visibleItems.last ? 2 : 0
            // Hover and marquee rendering do not change the measured width.
            // Preserve AppKit's expanded frame in that case; shrinking it here
            // would move the Settings chevron on the first highlight. Padding
            // and height still update when the first or last visible row changes.
            let size = NSSize(width: widthChanged ? width : row.frame.width, height: row.requiredHeight)
            if row.frame.size != size { row.setFrameSize(size) }
        }
    }

    private func inlineImage(_ image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: menuFont.descender, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    private func separatorImage(after action: String, highlighted: Bool, enabled: Bool) -> NSImage {
        let padding = columnWidth(for: action) - measure(action)
        let width = padding + separatorLeadingGap + 1 + separatorTrailingGap
        let height = ceil(menuFont.ascender - menuFont.descender + menuFont.leading)
        let barHeight = min(menuFont.pointSize, height - 2)
        let barX = padding + separatorLeadingGap
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let color: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
            color.withAlphaComponent(enabled ? 0.20 : 0.10).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX,
                                             y: (height - barHeight) / 2, width: 1, height: barHeight),
                         xRadius: 0.5, yRadius: 0.5).fill()
            return true
        }
    }

    private func albumIcon() -> NSImage? {
        AlbumIcon.image(side: 14)
    }

    private func exclusionIcon(named name: String) -> NSImage? {
        if name == "exclude-album" { return AlbumIcon.image(side: 14, showsExclusionBadge: true) }
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "MenuBarIcons"),
              let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(14 / image.size.width, 14 / image.size.height)
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.isTemplate = true
        return image
    }

    private func metadataIcon(_ icon: NSImage, highlighted: Bool, enabled: Bool) -> NSImage {
        let height = ceil(menuFont.ascender - menuFont.descender + menuFont.leading)
        let width = inlineIconWidth
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let rect = NSRect(x: 0, y: (height - icon.size.height) / 2,
                              width: icon.size.width, height: icon.size.height)
            icon.draw(in: rect)
            context.setBlendMode(.sourceIn)
            let color: NSColor = !enabled ? .disabledControlTextColor
                : highlighted ? .selectedMenuItemTextColor : .labelColor
            color.setFill()
            rect.fill()
            context.endTransparencyLayer()
            context.restoreGState()
            return true
        }
    }

    private func fadingName(_ name: String, width: CGFloat, offset: CGFloat, distance: CGFloat,
                            highlighted: Bool, enabled: Bool) -> NSImage {
        let font = menuFont
        let height = ceil(font.ascender - font.descender + font.leading)
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.clip(to: rect)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let color: NSColor = !enabled ? .disabledControlTextColor
                : highlighted ? .selectedMenuItemTextColor : .labelColor
            (name as NSString).draw(at: NSPoint(x: -offset, y: 0), withAttributes: [.font: font, .foregroundColor: color])
            // Apply opacity to the letters, leaving the native menu background intact.
            let edge = min(10, width / 4)
            let alphas: [CGFloat] = [offset > 0.5 ? 0 : 1, 1, 1, offset < distance - 0.5 ? 0 : 1]
            let colors = alphas.map { CGColor(gray: 0, alpha: $0) } as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors,
                                         locations: [0, edge / width, 1 - edge / width, 1]) {
                context.setBlendMode(.destinationIn)
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
            }
            context.endTransparencyLayer()
            context.restoreGState()
            return true
        }
    }

    private func measure(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: menuFont]).width
    }

    private func configure(_ item: NSMenuItem, title: String, action: Selector?, symbol: String? = nil) {
        item.title = title
        item.action = action
        item.target = self
        if let symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            if let image, image.size.width > 0, image.size.height > 0 {
                let scale = min(14 / image.size.width, 14 / image.size.height)
                image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            }
            image?.isTemplate = true
            item.image = image
        }
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let item = AccessibleMenuItem()
        configure(item, title: title, action: action)
        return item
    }

    @objc private func banArtist() { if let track = interactionTrack { onBanArtist?(track) } }
    @objc private func banAlbum() { if let track = interactionTrack { onBanAlbum?(track) } }
    @objc private func banTrack() { if let track = interactionTrack { onBanTrack?(track) } }
    @objc private func toggleFilter() { onToggle?() }
    @objc private func manage() { onManage?() }
    @objc private func about() { onAbout?() }
    @objc private func togglePreemptive() { onTogglePreemptive?() }
    @objc private func openAccessibilitySettings() { onOpenAccessibilitySettings?() }
    @objc private func toggleFollowMusic() { onToggleFollowMusic?() }
    @objc private func openLoginSettings() { onOpenLoginSettings?() }
    @objc private func quit() { onQuit?() }
}

/// Plain descriptive text inside the system menu. The menu owns its background.
@MainActor
private final class MenuTextRow: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let rowWidth: CGFloat = 260
    private let leadingInset: CGFloat = 28
    private let trailingInset: CGFloat = 20
    private(set) var text = ""

    init(text: String, maximumLines: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 36))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = maximumLines
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        addSubview(label)
        setText(text)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setText(_ text: String) {
        self.text = text
        label.stringValue = text
        label.setAccessibilityValue(text)
        let textWidth = rowWidth - leadingInset - trailingInset
        label.preferredMaxLayoutWidth = textWidth
        // Fit the actual text, including NSTextField's vertical cell allowance.
        // The controller freezes descriptive rows while their submenu tracks,
        // so no unused line needs to be reserved for a later status update.
        let height = ceil(label.fittingSize.height)
        frame.size = NSSize(width: rowWidth, height: height + 8)
        label.frame = NSRect(x: leadingInset, y: 4, width: textWidth, height: height)
    }
}

/// The native menu item remains the accessibility element and action owner.
/// Its custom drawing view supplies a live frame using only public conversions.
@MainActor
final class AccessibleMenuItem: NSMenuItem {
    private var actionWasSent = false

    func beginTracking() { actionWasSent = false }

    @discardableResult
    func performLeafAction() -> Bool {
        guard !actionWasSent, isEnabled, !isHiddenOrHasHiddenAncestor,
              submenu == nil, let menu, view?.window != nil else { return false }
        actionWasSent = true
        var root = menu
        while let parent = root.supermenu { root = parent }
        root.cancelTracking()
        let index = menu.index(of: self)
        guard index >= 0 else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        submenu == nil ? performLeafAction() : super.accessibilityPerformPress()
    }

    override func accessibilityFrame() -> NSRect {
        guard !isHiddenOrHasHiddenAncestor else { return .zero }
        guard let view else { return super.accessibilityFrame() }
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    override func accessibilityActivationPoint() -> NSPoint {
        let rect = accessibilityFrame()
        return NSPoint(x: rect.midX, y: rect.midY)
    }
}

/// Native NSMenu owns tracking and submenus. The row draws its own selection
/// and forwards leaf clicks through the menu item's guarded action path.
@MainActor
final class MenuActionRow: NSView {
    enum Tint { case blue, neutral, informational }

    var informationalContentAvailable = false {
        didSet { if oldValue != informationalContentAvailable { needsDisplay = true } }
    }

    var highlighted = false {
        didSet { if oldValue != highlighted { refreshSelection(); needsDisplay = true } }
    }
    var topRadius: CGFloat {
        didSet { if oldValue != topRadius { rebuildMask(); needsDisplay = true } }
    }
    var bottomRadius: CGFloat {
        didSet { if oldValue != bottomRadius { rebuildMask(); needsDisplay = true } }
    }
    var topPadding: CGFloat = 0 {
        didSet { if oldValue != topPadding { updateContentGeometry() } }
    }
    var bottomPadding: CGFloat = 0 {
        didSet { if oldValue != bottomPadding { updateContentGeometry() } }
    }
    var requiredHeight: CGFloat { 24 + max(0, topPadding) + max(0, bottomPadding) }
    private var contentRect: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY + max(0, topPadding), width: bounds.width,
               height: max(0, bounds.height - max(0, topPadding) - max(0, bottomPadding)))
    }
    private let tint: Tint
    private let showsStateColumn: Bool
    private let textColor: NSColor?
    private let font = NSFont.menuFont(ofSize: 0)
    private let selection = PassiveSelectionView()
    private let foreground = ForegroundView()
    private var maskSize = NSSize.zero

    init(tint: Tint, topRadius: CGFloat, bottomRadius: CGFloat, showsStateColumn: Bool = false,
         textColor: NSColor? = nil) {
        self.tint = tint
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.showsStateColumn = showsStateColumn
        self.textColor = textColor
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 24))
        autoresizingMask = [.width]
        setAccessibilityElement(false)
        selection.material = .selection
        selection.blendingMode = .withinWindow
        selection.state = .active
        selection.isEmphasized = true
        selection.isHidden = true
        selection.autoresizingMask = [.width, .height]
        selection.setAccessibilityElement(false)
        foreground.owner = self
        foreground.autoresizingMask = [.width]
        foreground.setAccessibilityElement(false)
        addSubview(selection)
        addSubview(foreground, positioned: .above, relativeTo: selection)
        selection.frame = bounds
        foreground.frame = contentRect
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // Controllers invalidate the row when attributed text or a checkmark changes.
    // Forward that invalidation to the drawing view above the material layer.
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { foreground.needsDisplay = true; refreshSelection() }
        }
    }

    func requiredWidth(for item: NSMenuItem) -> CGFloat {
        let width = item.attributedTitle?.size().width
            ?? (item.title as NSString).size(withAttributes: [.font: font]).width
        return ceil(titleLeading(for: item) + width + (item.submenu == nil ? 14 : 32))
    }

    override func mouseUp(with event: NSEvent) {
        guard tint != .informational else { return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)),
              let item = enclosingMenuItem as? AccessibleMenuItem else { return }
        if item.submenu == nil { item.performLeafAction() }
        else { super.mouseUp(with: event) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { (enclosingMenuItem as? AccessibleMenuItem)?.beginTracking() }
        else { highlighted = false }
        rebuildMask()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        selection.frame = bounds
        foreground.frame = contentRect
        if maskSize != bounds.size { rebuildMask() }
    }

    private func updateContentGeometry() {
        selection.frame = bounds
        foreground.frame = contentRect
        rebuildMask()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func refreshSelection() {
        let visible = tint == .blue && highlighted && (enclosingMenuItem?.isEnabled == true)
            && contentRect.width > 14 && contentRect.height > 0
        if selection.isHidden == visible { selection.isHidden = !visible }
    }

    private func rebuildMask() {
        maskSize = bounds.size
        guard contentRect.width > 14, contentRect.height > 0 else {
            selection.maskImage = nil
            refreshSelection()
            return
        }
        let path = selectionPath(in: contentRect.insetBy(dx: 7, dy: 0))
        selection.maskImage = NSImage(size: bounds.size, flipped: true) { _ in
            NSColor.white.setFill()
            path.fill()
            return true
        }
        refreshSelection()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard tint == .neutral, highlighted, enclosingMenuItem?.isEnabled == true else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        selectionPath(in: contentRect.insetBy(dx: 7, dy: 0)).fill()
    }

    private func titleLeading(for item: NSMenuItem) -> CGFloat {
        (showsStateColumn ? 28 : 16) + (item.image == nil ? 0 : 20)
    }

    private func drawForeground(in rect: NSRect) {
        guard let item = enclosingMenuItem else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()
        let contentEnabled = item.isEnabled || (tint == .informational && informationalContentAvailable)
        let active = highlighted && item.isEnabled && tint != .informational
        let color: NSColor = !contentEnabled ? .disabledControlTextColor
            : textColor ?? (active && tint == .blue ? .selectedMenuItemTextColor : .labelColor)
        if showsStateColumn {
            let stateImage: NSImage?
            switch item.state {
            case .on: stateImage = item.onStateImage
            case .mixed: stateImage = item.mixedStateImage
            default: stateImage = item.offStateImage
            }
            if let stateImage {
                drawImage(stateImage, in: NSRect(x: 10, y: (rect.height - 12) / 2, width: 12, height: 12),
                          color: color, forceTint: true, enabled: contentEnabled)
            }
        }
        if let image = item.image {
            let leading: CGFloat = showsStateColumn ? 28 : 16
            drawImage(image, in: NSRect(x: leading, y: (rect.height - 14) / 2, width: 14, height: 14),
                      color: color, forceTint: image.isTemplate, enabled: contentEnabled)
        }
        let title = NSMutableAttributedString(attributedString:
            item.attributedTitle ?? NSAttributedString(string: item.title, attributes: [.font: font]))
        title.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: title.length))
        let titleHeight = ceil(title.size().height)
        let leading = titleLeading(for: item)
        let rightInset: CGFloat = item.submenu == nil ? 14 : 32
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: leading, y: 0, width: max(0, rect.width - leading - rightInset),
                                 height: rect.height)).addClip()
        title.draw(at: NSPoint(x: leading, y: (rect.height - titleHeight) / 2))
        NSGraphicsContext.restoreGraphicsState()
        if item.submenu != nil,
           let arrow = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
            drawImage(arrow, in: NSRect(x: rect.width - 22, y: (rect.height - 11) / 2, width: 7, height: 11),
                      color: color, forceTint: true, enabled: contentEnabled)
        }
    }

    private func drawImage(_ image: NSImage, in slot: NSRect, color: NSColor,
                           forceTint: Bool, enabled: Bool) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(slot.width / image.size.width, slot.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                          width: size.width, height: size.height)
        guard forceTint else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: enabled ? 1 : 0.45,
                       respectFlipped: true, hints: nil)
            return
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        rect.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func selectionPath(in rect: NSRect) -> NSBezierPath {
        let top = min(topRadius, rect.height / 2)
        let bottom = min(bottomRadius, rect.height / 2)
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        let shoulder: CGFloat = 0.72
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0 + top, y: y0))
        path.line(to: NSPoint(x: x1 - top, y: y0))
        path.curve(to: NSPoint(x: x1, y: y0 + top),
                   controlPoint1: NSPoint(x: x1 - top + top * shoulder, y: y0),
                   controlPoint2: NSPoint(x: x1, y: y0 + top - top * shoulder))
        path.line(to: NSPoint(x: x1, y: y1 - bottom))
        path.curve(to: NSPoint(x: x1 - bottom, y: y1),
                   controlPoint1: NSPoint(x: x1, y: y1 - bottom + bottom * shoulder),
                   controlPoint2: NSPoint(x: x1 - bottom + bottom * shoulder, y: y1))
        path.line(to: NSPoint(x: x0 + bottom, y: y1))
        path.curve(to: NSPoint(x: x0, y: y1 - bottom),
                   controlPoint1: NSPoint(x: x0 + bottom - bottom * shoulder, y: y1),
                   controlPoint2: NSPoint(x: x0, y: y1 - bottom + bottom * shoulder))
        path.line(to: NSPoint(x: x0, y: y0 + top))
        path.curve(to: NSPoint(x: x0 + top, y: y0),
                   controlPoint1: NSPoint(x: x0, y: y0 + top - top * shoulder),
                   controlPoint2: NSPoint(x: x0 + top - top * shoulder, y: y0))
        path.close()
        return path
    }

    private final class PassiveSelectionView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class ForegroundView: NSView {
        weak var owner: MenuActionRow?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { owner?.drawForeground(in: bounds) }
    }
}
