import AppKit
import OSLog
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: BanStore!
    private let music = MusicController()
    private var gate = SkipGate()
    private var navigation = PlaybackNavigation()
    private var lastPlaybackChange: TimeInterval = 0
    private var timer: Timer?
    private var session = MusicSessionState()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lifecycleTimer: Timer?
    private let lifecycleLog = Logger(subsystem: "dev.julienmerault.FiltreMusique", category: "lifecycle")
    private let launchAtLogin = LaunchAtLogin()
    private var launchedAtLogin = false
    private var followMusic = true
    private var manualPresentation = false
    private let upcoming = MusicQueueController()
    private var preemptiveEnabled = false
    private var queueRequest: UUID?
    private var lastQueueCheck: TimeInterval = 0
    private var queueRemovals: [UUID: TimeInterval] = [:]
    private var preemptivePaused = false
    private var queueStatus = ""
    private var queueBackoff = QueueScanBackoff()
    private let queueLog = Logger(subsystem: "dev.julienmerault.FiltreMusique", category: "queue")
    private var currentTrack: TrackSnapshot?
    private var statusItem: NSStatusItem!
    private var exclusionIndicator: StatusActivityIndicator?
    private var statusMenuPresenter: StatusMenuPresenter?
    private var recentAutomaticExclusion = RecentAutomaticExclusion()
    private var panel: StatusMenuController!
    private var manager: ExclusionsWindowController?
    private let artwork = ExclusionArtworkProvider()
    private var enabled = true
    private let menuBarIcon = MenuBarIcon.musicHand7
    private var status = ""
    private var lastSkipped: String?
    private var automationDenied = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = LaunchAtLogin.isLoginLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Music Filter", isDirectory: true)
            store = try BanStore(fileURL: folder.appendingPathComponent("exclusions.json"))
        } catch {
            showError(error); NSApp.terminate(nil); return
        }
        enabled = UserDefaults.standard.object(forKey: "filterEnabled") as? Bool ?? true
        let savedFollowMusic = UserDefaults.standard.object(forKey: "followMusic") as? Bool
        followMusic = savedFollowMusic ?? true
        preemptiveEnabled = UserDefaults.standard.bool(forKey: "preemptiveFiltering")
        if CommandLine.arguments.contains("--queue-diagnostics") {
            runQueueDiagnostics()
            return
        }
        if savedFollowMusic == nil {
            do {
                try launchAtLogin.setEnabled(true)
                UserDefaults.standard.set(true, forKey: "followMusic")
            } catch {
                followMusic = false
                UserDefaults.standard.set(false, forKey: "followMusic")
                showError(error)
            }
        } else if !UserDefaults.standard.bool(forKey: "coupledMusicStartupMigrated") {
            // Keep a previously disabled login item disabled when the old two
            // switches become one. Do not silently undo an OS-side revocation.
            if launchAtLogin.state == .disabled || launchAtLogin.state == .unavailable {
                followMusic = false
                UserDefaults.standard.set(false, forKey: "followMusic")
            } else if launchAtLogin.state == .enabled {
                followMusic = true
                UserDefaults.standard.set(true, forKey: "followMusic")
            }
        }
        UserDefaults.standard.set(true, forKey: "coupledMusicStartupMigrated")
        launchedAtLogin = launchedAtLogin || LaunchAtLogin.isLoginLaunch()
        manualPresentation = !launchedAtLogin
        installMainMenu()
        panel = StatusMenuController()
        panel.setIconPlacement(MenuIconPlacement(rawValue: UserDefaults.standard.string(forKey: "menuIconPlacement") ?? "") ?? .beforeActions)
        panel.setExclusionIconBadgesEnabled(UserDefaults.standard.bool(forKey: "exclusionIconBadges"))
        let redDotPosition = RedDotPosition(rawValue: UserDefaults.standard.string(forKey: "redDotPosition") ?? "") ?? .upperRight
        panel.onBanArtist = { [weak self] track in self?.banArtist(track) }
        panel.onBanAlbum = { [weak self] track in self?.banAlbum(track) }
        panel.onBanTrack = { [weak self] track in self?.banTrack(track) }
        panel.onToggle = { [weak self] in self?.toggleFilter() }
        panel.onManage = { [weak self] in
            self?.statusMenuPresenter?.performAfterTracking { [weak self] in self?.showManager() }
        }
        panel.onAbout = { [weak self] in
            self?.statusMenuPresenter?.performAfterTracking { [weak self] in self?.showAbout() }
        }
        panel.onToggleFollowMusic = { [weak self] in self?.toggleFollowMusic() }
        panel.onOpenLoginSettings = { [weak self] in self?.launchAtLogin.openSystemSettings() }
        panel.onTogglePreemptive = { [weak self] in self?.togglePreemptive() }
        panel.onOpenAccessibilitySettings = { [weak self] in self?.openAccessibilitySettings() }
        panel.onQuit = { NSApp.terminate(nil) }
        panel.onWillOpen = { [weak self] in
            self?.reconcileMusicProcess(reason: "menu")
            self?.poll(); self?.pollUpcoming(); self?.refreshUI(); self?.refreshStartupOptions()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.setAccessibilityLabel("Music Filter")
            button.setAccessibilityIdentifier("musicFilter.statusItem")
            // Present the native menus from the button action. Assigning a
            // statusItem.menu deactivates an active accessory app before it
            // opens, briefly moving our windows behind the previous app.
            statusItem.menu = nil
            panel.onRecentExclusionMenuWillOpen = { [weak self] in
                self?.recentAutomaticExclusion.song(at: ProcessInfo.processInfo.systemUptime)?.displayName
            }
            statusMenuPresenter = StatusMenuPresenter(button: button, primaryMenu: panel.menu,
                recentMenu: panel.recentExclusionMenu, statusItem: statusItem)
        }
        updateMenuBarIcon()
        if let button = statusItem.button {
            exclusionIndicator = StatusActivityIndicator(button: button)
            exclusionIndicator?.setPosition(redDotPosition)
        }
        refreshStartupOptions()
        observeMusicLifecycle()
        refreshUI()
        // Startup stays quiet, especially when macOS opens the app at login.
        // Explicit reopening still reveals the menu, even while Music is closed.
    }

    private func updateMenuBarIcon() {
        let image = menuBarIcon.image() ?? NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Music Filter")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reconcileMusicProcess(reason: "reopen")
        manualPresentation = true
        updatePresence()
        showStatusMenu(); return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        reconcileMusicProcess(reason: "activation")
        refreshStartupOptions()
        refreshPreemptiveUI()
        pollUpcoming()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuPresenter?.invalidate()
        statusMenuPresenter = nil
        exclusionIndicator?.reset()
        timer?.invalidate(); timer = nil
        lifecycleTimer?.invalidate(); lifecycleTimer = nil
        session.stop()
        music.invalidatePendingOperations()
        cancelUpcoming()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    private var runningMusicProcessID: Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            .first(where: { !$0.isTerminated })?.processIdentifier
    }

    private func observeMusicLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == "com.apple.Music" else { return }
                let reason = name == NSWorkspace.didLaunchApplicationNotification ? "workspaceLaunch" : "workspaceTermination"
                MainActor.assumeIsolated { self?.reconcileMusicProcess(reason: reason) }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileMusicProcess(reason: "wake"); self?.poll() }
        })
        // Notifications are hints, not the only source of truth. The resident
        // watchdog reads NSWorkspace's process inventory only; it sends no
        // AppleEvents and also catches launches while our session is nil.
        if lifecycleTimer == nil {
            let observer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileMusicProcess(reason: "watchdog") }
            }
            observer.tolerance = 0.5
            lifecycleTimer = observer
            RunLoop.main.add(observer, forMode: .common)
        }
        reconcileMusicProcess(reason: "launch")
    }

    private func reconcileMusicProcess(reason: String = "request") {
        guard store != nil, statusItem != nil else { return }
        let processID = runningMusicProcessID
        let previousProcessID = session.processID
        let changed = session.reconcile(processID: processID)
        if changed || reason != "watchdog" {
            lifecycleLog.notice("Music lifecycle via \(reason, privacy: .public); previous PID: \(previousProcessID ?? 0, privacy: .public); observed PID: \(processID ?? 0, privacy: .public); changed: \(changed, privacy: .public); generation: \(self.session.generation, privacy: .public)")
        }
        guard changed else {
            // The first absent observation still applies the login visibility
            // preference. Stable watchdog ticks do not refresh the interface.
            if reason != "watchdog" { updatePresence(); refreshUI() }
            return
        }
        if changed {
            exclusionIndicator?.reset()
            timer?.invalidate(); timer = nil
            music.invalidatePendingOperations()
            cancelUpcoming()
            queueBackoff.reset()
            if !preemptivePaused { queueStatus = "" }
            if reason != "menu" { panel?.menu.cancelTracking() }
            currentTrack = nil
            lastSkipped = nil
            status = ""
            automationDenied = false
            gate.reset()
            navigation.reset()
            lastPlaybackChange = ProcessInfo.processInfo.systemUptime
            manualPresentation = false
            if processID != nil {
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.poll(); self?.pollUpcoming() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        updatePresence()
        refreshUI()
        if changed, processID != nil { poll() }
    }

    private func updatePresence() {
        statusItem?.isVisible = !followMusic || session.processID != nil || manualPresentation
    }

    private func refreshStartupOptions() {
        let state = launchAtLogin.state
        panel?.setStartupOptions(launchAtLogin: state == .enabled,
                                 needsApproval: followMusic && state != .enabled, followMusic: followMusic)
    }

    private func toggleFollowMusic() {
        let requested = !followMusic
        do {
            try launchAtLogin.setEnabled(requested)
            followMusic = requested
            UserDefaults.standard.set(followMusic, forKey: "followMusic")
        } catch { showError(error) }
        manualPresentation = false
        updatePresence()
        refreshStartupOptions()
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: L("About Music Filter", "À propos de Music Filter"),
                                   action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit Music Filter", "Quitter Music Filter"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: L("Edit", "Édition"))
        for (title, action, key) in [(L("Cut", "Couper"), "cut:", "x"), (L("Copy", "Copier"), "copy:", "c"), (L("Paste", "Coller"), "paste:", "v"), (L("Select All", "Tout sélectionner"), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
    }

    private func showStatusMenu() {
        guard statusItem?.isVisible == true, panel != nil else { return }
        poll()
        refreshUI()
        statusMenuPresenter?.presentPrimaryMenu()
    }

    private func refreshUI() {
        guard panel != nil, store != nil else { return }
        let message: String
        if !status.isEmpty { message = status }
        else if session.processID == nil { message = L("Music is closed. Filtering resumes when it opens.", "Musique est fermée. Le filtre reprendra à son ouverture.") }
        else if currentTrack == nil { message = L("Select a song in Music to choose what to exclude.", "Choisissez un morceau dans Musique pour l’exclure.") }
        else { message = "" }
        panel.update(track: currentTrack, enabled: enabled, status: message, count: store.rules.count, lastSkipped: lastSkipped)
        refreshPreemptiveUI()
        statusItem?.button?.appearsDisabled = !enabled
    }

    private func poll() {
        guard !automationDenied, let token = session.beginRequest() else { return }
        music.read(expectedProcessID: token.processID) { [weak self] result in
            guard let self, self.session.finishRequest(token) else { return }
            guard self.runningMusicProcessID == token.processID else {
                self.reconcileMusicProcess(); return
            }
            switch result {
            case .success(let track):
                self.observePlayback(track)
                if !self.status.hasPrefix("⚠︎") { self.status = "" }
                self.refreshUI()
                if let track, self.enabled { self.applyFilter(to: track) }
            case .failure(let error):
                self.observePlayback(nil)
                self.status = interfaceErrorDescription(error)
                if case MusicControlError.automationDenied = error { self.automationDenied = true }
                self.refreshUI()
            }
        }
    }

    private func observePlayback(_ track: TrackSnapshot?) {
        if currentTrack?.identity != track?.identity || currentTrack?.isPlaying != track?.isPlaying {
            // A queue witness belongs to one playback state. Going backwards,
            // forwards or pausing invalidates it; its late callback must not
            // pause the new state. The worker still quarantines any uncertain
            // deletion and the callback still accounts for its action budget.
            cancelUpcoming()
            lastPlaybackChange = ProcessInfo.processInfo.systemUptime
            queueBackoff.reset()
            if !preemptivePaused { queueStatus = "" }
        }
        navigation.observe(track)
        currentTrack = track
    }

    private func applyFilter(to track: TrackSnapshot) {
        guard session.processID != nil, session.processID == runningMusicProcessID else {
            reconcileMusicProcess(); return
        }
        let decision = gate.evaluate(trackID: track.identity, isBlocked: store.matchingRule(for: track) != nil,
            isPlaying: track.isPlaying)
        guard decision != .none, let token = session.beginRequest() else { return }
        let direction = navigation.direction
        cancelUpcoming()
        lastPlaybackChange = ProcessInfo.processInfo.systemUptime
        if decision == .requiresPause {
            enabled = false
            cancelUpcoming()
            UserDefaults.standard.set(false, forKey: "filterEnabled")
            status = "⚠︎ " + L("Filtering paused after too many excluded songs in a row. Check your exclusions, then turn the filter back on.", "Filtre suspendu : trop de morceaux exclus à la suite. Vérifiez vos exclusions, puis réactivez le filtre.")
        }
        music.skip(track, direction: direction, pauseInstead: decision == .requiresPause, expectedProcessID: token.processID) { [weak self] result in
            guard let self, self.session.finishRequest(token) else { return }
            guard self.runningMusicProcessID == token.processID else {
                self.reconcileMusicProcess(); return
            }
            switch result {
            case .success(let applied):
                if applied && decision == .skip {
                    self.navigation.didSkip(in: direction)
                    self.lastSkipped = "\(track.title) · \(track.artist)"
                    self.recordAutomaticExclusion(title: track.title, artist: track.artist)
                }
            case .failure(let error):
                self.enabled = false
                self.cancelUpcoming()
                UserDefaults.standard.set(false, forKey: "filterEnabled")
                self.status = "⚠︎ " + interfaceErrorDescription(error)
            }
            self.refreshUI()
        }
    }

    private func recordAutomaticExclusion(title: String, artist: String) {
        recentAutomaticExclusion.record(title: title, artist: artist, at: ProcessInfo.processInfo.systemUptime)
        exclusionIndicator?.pulse()
    }

    private func toggleFilter() {
        cancelUpcoming()
        enabled.toggle(); gate.reset(); automationDenied = false; status = ""
        UserDefaults.standard.set(enabled, forKey: "filterEnabled")
        refreshUI(); poll()
    }

    private func cancelUpcoming() {
        upcoming.setEnabled(false)
        queueRequest = nil
        lastQueueCheck = 0
    }

    private func togglePreemptive() {
        cancelUpcoming()
        upcoming.resetRemovalAttempts()
        preemptiveEnabled.toggle()
        preemptivePaused = false
        queueBackoff.reset()
        queueRemovals.removeAll()
        queueStatus = ""
        UserDefaults.standard.set(preemptiveEnabled, forKey: "preemptiveFiltering")
        refreshPreemptiveUI()
        pollUpcoming()
    }

    private func openAccessibilitySettings() {
        panel?.menu.cancelTracking()
        upcoming.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshPreemptiveUI() {
        guard panel != nil else { return }
        let trusted = upcoming.isAccessibilityTrusted
        let message: String
        if !preemptiveEnabled { message = "" }
        else if !trusted { message = "" }
        else if !enabled { message = L("Paused with automatic filtering.", "En pause avec le filtrage automatique.") }
        else if session.processID == nil { message = L("Waiting for Music.", "En attente de Musique.") }
        else { message = queueStatus }
        panel.setPreemptiveOptions(enabled: preemptiveEnabled, needsPermission: !trusted, status: message)
    }

    private func pollUpcoming() {
        guard store != nil, preemptiveEnabled, enabled, !preemptivePaused,
              upcoming.isAccessibilityTrusted, queueRequest == nil,
              let processID = session.processID, processID == runningMusicProcessID,
              let track = currentTrack,
              store.matchingRule(for: track) == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPlaybackChange >= 1.25,
              now - lastQueueCheck >= 2, queueBackoff.allowsAttempt(at: now) else { return }
        queueRemovals = queueRemovals.filter { now - $0.value < 30 }
        guard queueRemovals.count < 8 else {
            preemptivePaused = true
            queueStatus = L("Upcoming filtering paused after repeated removals. Toggle it to resume.",
                            "Filtrage anticipé en pause après plusieurs retraits. Désactivez puis réactivez l’option.")
            cancelUpcoming()
            refreshPreemptiveUI()
            return
        }
        lastQueueCheck = now
        let request = UUID()
        let generation = session.generation
        queueRequest = request
        // Reserve the one possible action before dispatch, including while a
        // cancelled worker is finishing. Only a proven zero-attempt refunds it.
        queueRemovals[request] = now
        upcoming.setEnabled(true)
        upcoming.filterUpcoming(processID: processID, rules: store.rules,
                                 currentTrack: track,
                                 dryRun: false, maxRemovals: 1) { [weak self] report in
            guard let self else { return }
            if report.removalAttempts > 0 {
                self.queueLog.notice("Queue removal attempts: \(report.removalAttempts, privacy: .public); confirmed: \(report.removed.count, privacy: .public)")
                if !report.confirmationTrace.isEmpty {
                    self.queueLog.notice("Queue confirmation observations: \(report.confirmationTrace.joined(separator: " | "), privacy: .public)")
                }
            }
            if report.removalAttempts == 0 { self.queueRemovals.removeValue(forKey: request) }
            else { self.queueRemovals[request] = ProcessInfo.processInfo.systemUptime }
            guard self.queueRequest == request else { return }
            self.queueRequest = nil
            guard self.session.generation == generation, self.runningMusicProcessID == processID else {
                self.reconcileMusicProcess(); return
            }
            if let removed = report.removed.last { self.recordAutomaticExclusion(title: removed.title, artist: removed.artist) }
            if case .failed(let reason) = report.status {
                self.queueLog.error("Queue scan failed: \(reason, privacy: .public); phase: \(report.phase, privacy: .public); calls: \(report.axCalls, privacy: .public); seconds: \(report.elapsedSeconds, privacy: .public); exhausted: \(report.budgetExhausted, privacy: .public); call limit: \(report.callLimitReached, privacy: .public); time limit: \(report.timeLimitReached, privacy: .public)")
            }
            // A command may have reached Music despite a timeout or cancellation.
            // Never recover automatically when its removal is unconfirmed.
            if report.removalAttempts > report.removed.count {
                self.preemptivePaused = true
                self.cancelUpcoming()
                self.queueStatus = L("Upcoming filtering paused after an unconfirmed removal. Turn the option off and on to retry.",
                                     "Retrait non confirmé. Désactivez puis réactivez le filtrage anticipé pour réessayer.")
                self.refreshPreemptiveUI()
                return
            }
            switch report.status {
            case .ready:
                self.queueStatus = ""
                self.queueBackoff.reset()
            case .queueNotVisible:
                self.queueStatus = L("Keep the Music window open (not minimized), even in the background, with the queue displayed.",
                                     "Vous devez garder la fenêtre de Musique ouverte (non réduite), même en arrière-plan, avec la file d’attente affichée.")
                self.queueBackoff.reset()
            case .upcomingNotVisible:
                self.queueStatus = L("Show the upcoming songs in Music’s queue.",
                                     "Affichez les prochains morceaux dans la file d’attente de Musique.")
                self.queueBackoff.reset()
            case .metadataUnavailable:
                self.queueStatus = L("Queue details unavailable. Regular skipping remains active.",
                                     "Informations de file indisponibles. Le saut habituel reste actif.")
                self.queueBackoff.reset()
            case .accessibilityRequired:
                self.queueStatus = ""
                self.cancelUpcoming()
            case .musicNotRunning:
                self.reconcileMusicProcess()
            case .failed:
                if report.removalAttempts == 0 {
                    let delay = self.queueBackoff.recordPreActionFailure(at: ProcessInfo.processInfo.systemUptime)
                    self.queueLog.notice("Queue scan deferred for \(delay, privacy: .public) seconds; no removal was attempted")
                    self.queueStatus = L("Could not verify the queue. Retrying automatically; regular skipping remains active.",
                                         "File indisponible. Nouvelle tentative automatique ; le saut habituel reste actif.")
                } else {
                    // Every attempted action was confirmed; no uncertain command
                    // remains to retry, even if a later read failed.
                    self.queueBackoff.reset()
                    self.queueStatus = ""
                }
            case .disabled, .busy, .cancelled: break
            }
            self.refreshPreemptiveUI()
        }
    }

    /// Explicit read-only diagnostic. It never installs a timer or requests permission.
    private func runQueueDiagnostics() {
        guard let processID = runningMusicProcessID else {
            printQueueDiagnostic(.init(status: .musicNotRunning)); return
        }
        upcoming.setEnabled(true)
        upcoming.filterUpcoming(processID: processID, rules: store.rules,
            currentTrack: nil,
            dryRun: true, maxRemovals: 0, captureDiagnostics: true) { [weak self] report in
                self?.printQueueDiagnostic(report)
        }
    }

    private func printQueueDiagnostic(_ report: MusicQueueController.Report) {
        func fields(_ metadata: QueueTrackMetadata) -> [String: String] {
            ["title": metadata.title, "artist": metadata.artist, "album": metadata.album]
        }
        let value: [String: Any] = [
            "status": String(describing: report.status), "dryRun": true,
            "candidates": report.candidates.map(fields), "matching": report.matching.map(fields),
            "removed": report.removed.map(fields),
            "removalAttempts": report.removalAttempts,
            "phase": report.phase, "axCalls": report.axCalls,
            "elapsedSeconds": report.elapsedSeconds,
            "budgetExhausted": report.budgetExhausted,
            "callLimitReached": report.callLimitReached,
            "timeLimitReached": report.timeLimitReached,
            "confirmationTrace": report.confirmationTrace,
            "deleteAction": report.observedDeletionActionNameString ?? "",
            "diagnostics": report.diagnostics.map { row in
                ["rowIndex": row.rowIndex, "section": row.section?.rawValue ?? "", "values": row.values, "actions": row.actions,
                 "fields": row.fields.map { ["path": $0.path, "attribute": $0.attribute,
                                              "identifier": $0.identifier ?? "", "role": $0.role ?? "", "value": $0.value] }] as [String: Any]
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        NSApp.terminate(nil)
    }

    private func save(onError: ((Error) -> Void)? = nil, _ change: () throws -> Void) {
        cancelUpcoming()
        do { try change(); refreshUI(); reloadManager(); poll() }
        catch {
            if let onError { onError(error) }
            else { showError(error) }
        }
    }

    private func banArtist(_ track: TrackSnapshot) {
        save { try store.addArtist(track.artist) }
    }

    private func banTrack(_ track: TrackSnapshot) {
        save { try store.addTrack(track) }
    }

    private func banAlbum(_ track: TrackSnapshot) {
        save { try store.addAlbum(track) }
    }

    private func showError(_ error: Error) {
        panel?.menu.cancelTracking()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Music Filter"
        alert.informativeText = interfaceErrorDescription(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK", "OK"))
        alert.runModal()
    }

    @objc private func showAbout() {
        panel?.menu.cancelTracking()
        MusicFilterAbout.show()
    }

    private func showManager() {
        panel?.menu.cancelTracking()
        manualPresentation = true
        updatePresence()
        if manager == nil {
            let controller = ExclusionsWindowController()
            controller.onUnblock = { [weak self] id in
                guard let self else { return }
                self.save { try self.store.remove(id: id) }
            }
            controller.onImport = { [weak self] in self?.importExclusions() }
            controller.onExport = { [weak self] in self?.exportExclusions() }
            controller.onDeleteAll = { [weak self] in self?.deleteAllExclusions() }
            controller.loadArtwork = { [weak self] rule, completion in
                self?.artwork.load(for: rule, completion: completion)
            }
            manager = controller
        }
        reloadManager()
        manager?.showCentered()
    }

    private func reloadManager() {
        manager?.update(rules: store.rules)
    }

    private func exportExclusions() {
        guard let window = manager?.window, window.attachedSheet == nil else { return }
        let savePanel = NSSavePanel()
        savePanel.title = L("Export exclusions", "Exporter les exclusions")
        savePanel.message = L("Save all your excluded artists, albums and songs in a file.",
                              "Enregistrez tous vos artistes, albums et morceaux exclus dans un fichier.")
        savePanel.prompt = L("Export", "Exporter")
        savePanel.allowedContentTypes = [.json]
        savePanel.allowsOtherFileTypes = false
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        savePanel.nameFieldStringValue = "Music Filter Exclusions \(date.string(from: Date())).json"
        // An explicit file action must receive keyboard input even when the
        // nonactivating exclusions panel was used while another app was active.
        NSApp.activate()
        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            // The file sheet must detach before an error sheet can be shown.
            DispatchQueue.main.async {
                guard let self else { return }
                do { try self.store.exportedData().write(to: url, options: .atomic) }
                catch {
                    self.showTransferAlert(title: L("Export failed", "Échec de l’exportation"),
                                           message: interfaceErrorDescription(error),
                                           style: .warning, for: window)
                }
            }
        }
    }

    private func importExclusions() {
        guard let window = manager?.window, window.attachedSheet == nil else { return }
        let openPanel = NSOpenPanel()
        openPanel.title = L("Import exclusions", "Importer des exclusions")
        openPanel.message = L("Choose an exported Music Filter list. Your current exclusions will be kept, without duplicates.",
                              "Choisissez une liste exportée depuis Music Filter. Vos exclusions actuelles seront conservées, sans doublons.")
        openPanel.prompt = L("Import", "Importer")
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsOtherFileTypes = false
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        NSApp.activate()
        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                var result: BanStore.ImportResult?
                self.save(onError: { error in
                    self.showTransferAlert(title: L("Import failed", "Échec de l’importation"),
                                           message: interfaceErrorDescription(error) + "\n\n" +
                                               L("Your exclusions have not been changed.", "Vos exclusions n’ont pas été modifiées."),
                                           style: .warning, for: window)
                }) {
                    let data = try Self.readExclusionImport(at: url)
                    result = try self.store.importData(data)
                }
                guard let result else { return }
                let added = result.addedCount == 1
                    ? L("1 exclusion added.", "1 exclusion ajoutée.")
                    : L("\(result.addedCount) exclusions added.", "\(result.addedCount) exclusions ajoutées.")
                let duplicates = result.duplicateCount == 1
                    ? L("1 duplicate ignored.", "1 doublon ignoré.")
                    : L("\(result.duplicateCount) duplicates ignored.", "\(result.duplicateCount) doublons ignorés.")
                self.showTransferAlert(title: L("Import complete", "Import terminé"),
                                       message: added + "\n" + duplicates + "\n\n" +
                                           L("Your existing exclusions have been kept.", "Vos exclusions existantes ont été conservées."),
                                       style: .informational, for: window)
            }
        }
    }

    private func deleteAllExclusions() {
        guard let window = manager?.window, window.attachedSheet == nil, !store.rules.isEmpty else { return }
        let count = store.rules.count
        let alert = NSAlert()
        alert.messageText = L("Delete all exclusions?", "Supprimer toutes les exclusions ?")
        let scope = count == 1
            ? L("The saved exclusion will be deleted.", "L’exclusion enregistrée sera supprimée.")
            : L("All \(count) saved artist, album and song exclusions will be deleted.",
                "Les \(count) exclusions enregistrées d’artistes, d’albums et de morceaux seront supprimées.")
        alert.informativeText = scope + "\n\n" + L(
            "This cannot be undone. You can export your list before continuing.",
            "Cette action ne peut pas être annulée. Vous pouvez exporter votre liste avant de continuer.")
        alert.alertStyle = .warning
        let cancel = alert.addButton(withTitle: L("Cancel", "Annuler"))
        cancel.keyEquivalent = "\r"
        let delete = alert.addButton(withTitle: L("Delete all", "Tout supprimer"))
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        NSApp.activate()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.save(onError: { error in
                    self.showTransferAlert(title: L("Deletion failed", "Échec de la suppression"),
                                           message: interfaceErrorDescription(error) + "\n\n" +
                                               L("Your exclusions have not been changed.", "Vos exclusions n’ont pas été modifiées."),
                                           style: .warning, for: window)
                }) {
                    try self.store.removeAll()
                }
            }
        }
    }

    private static func readExclusionImport(at url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = BanStore.maximumImportBytes
        var data = Data()
        // Read at most one byte beyond the bound, including short reads, so a
        // large file is rejected without ever loading the whole file in memory.
        while data.count <= limit {
            let count = min(64 * 1024, limit + 1 - data.count)
            guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    private func showTransferAlert(title: String, message: String, style: NSAlert.Style, for window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: L("OK", "OK"))
        alert.beginSheetModal(for: window)
    }
}
