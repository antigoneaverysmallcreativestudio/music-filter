import AppKit

#if canImport(FiltreCore)
import FiltreCore
#endif

@MainActor
final class ExclusionsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate, NSWindowDelegate, NSSplitViewDelegate, NSMenuDelegate {
    var onUnblock: ((UUID) -> Void)?
    var onImport: (() -> Void)?
    var onExport: (() -> Void)?
    var onDeleteAll: (() -> Void)?
    var loadArtwork: ((BanRule, @escaping (NSImage?) -> Void) -> Void)? {
        didSet { reloadContent() }
    }

    private var rules: [BanRule] = []
    private var visibleRules: [BanRule] = []
    private var recentSongRules: [BanRule] = []
    private var albumSections: [[BanRule]] = []
    private var category: ExclusionCategory = .songs
    private var sidebarButtons: [ExclusionSidebarButton] = []
    private let sidebarSplit = NSSplitView()
    private let minimumSidebarWidth: CGFloat = 104
    private let maximumSidebarWidth: CGFloat = 220
    private let initialSidebarWidth: CGFloat = 176
    private let heading = NSTextField(labelWithString: "")
    private var bodyTop: NSLayoutConstraint?
    private let search = NSTextField(string: "")
    private let searchMagnifier = NSImageView()
    private let searchClearButton = NSButton()
    private let searchButton = ExclusionSidebarButton()
    private let deleteAllItem = AccessibleMenuItem()
    private let transferOptionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var searchCapsule: NSView?
    private var searchCapsuleTop: NSLayoutConstraint?
    private var searchPlacementWork: DispatchWorkItem?
    private var searchDismissMonitor: Any?
    private let artistTable = ExclusionContextTable()
    private let songTable = ExclusionContextTable()
    private let recentSongTable = ExclusionContextTable()
    private let songsContent = NSView()
    private let recentSongHeading = NSTextField(labelWithString: L("Recently excluded songs", "Morceaux exclus récemment"))
    private let allSongHeading = NSTextField(labelWithString: L("Excluded songs", "Morceaux exclus"))
    private let songCount = NSTextField(labelWithString: "")
    private let recentSongCount = NSTextField(labelWithString: "")
    private var songSortKey = "title"
    private var songSortAscending = true
    private var songColumnsHeader: ExclusionColumnHeaderView?
    private let recentSongNote = NSTextField(labelWithString: L("No recent songs match your search.", "Aucun morceau récent ne correspond à votre recherche."))
    private let recentSongScroll = ExclusionFixedScrollView()
    private let songFade = ExclusionScrollFadeView()
    private var recentSongHeight: NSLayoutConstraint?
    private let albums = ExclusionCollectionView()
    private let artistScroll = NSScrollView()
    private let songScroll = NSScrollView()
    private let albumScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 400))
    private let emptyView = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(wrappingLabelWithString: "")
    private var artworkCache: [UUID: NSImage] = [:]

    init() {
        let window = MusicFilterPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("Exclusions", "Exclusions")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed
        window.minSize = window.frame.size
        window.maxSize = window.frame.size
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
        buildWindow()
        positionWindowControls()
        reloadContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let searchDismissMonitor { NSEvent.removeMonitor(searchDismissMonitor) }
    }

    func update(rules: [BanRule]) {
        self.rules = rules
        let ids = Set(rules.map(\.id))
        artworkCache = artworkCache.filter { ids.contains($0.key) }
        reloadContent()
    }

    func showCentered() {
        guard let window else { return }
        category = .songs
        dismissSearch()
        reloadContent()
        if window.isMiniaturized { window.deminiaturize(nil) }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let width = window.frame.width
            let height = window.frame.height
            let x = frame.midX - width / 2
            let y = frame.midY - height / 2
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        }
        // This is an explicit window command, after status-menu tracking ends.
        NSApp.activate()
        window.makeKey()
        window.orderFrontRegardless()
    }

    @objc private func importExclusions(_ sender: Any?) {
        // Let the native popup finish tracking before attaching a file sheet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.attachedSheet == nil else { return }
            self.onImport?()
        }
    }

    @objc private func exportExclusions(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.attachedSheet == nil else { return }
            self.onExport?()
        }
    }

    @objc private func deleteAllExclusions(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.attachedSheet == nil, !self.rules.isEmpty else { return }
            self.onDeleteAll?()
        }
    }

    private func sizeTransferMenu(_ menu: NSMenu) {
        let rows = menu.items.compactMap { item -> (NSMenuItem, MenuActionRow)? in
            guard let row = item.view as? MenuActionRow else { return nil }
            return (item, row)
        }
        let width = rows.map { $0.1.requiredWidth(for: $0.0) }.max() ?? 0
        for (_, row) in rows { row.setFrameSize(NSSize(width: width, height: row.requiredHeight)) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === transferOptionsButton.menu else { return }
        sizeTransferMenu(menu)
        for item in menu.items {
            (item as? AccessibleMenuItem)?.beginTracking()
            (item.view as? MenuActionRow)?.highlighted = false
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === transferOptionsButton.menu else { return }
        for candidate in menu.items {
            (candidate.view as? MenuActionRow)?.highlighted = candidate === item
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === transferOptionsButton.menu else { return }
        for item in menu.items { (item.view as? MenuActionRow)?.highlighted = false }
    }

    private func positionWindowControls() {
        guard let window, let root = window.contentView,
              let close = window.standardWindowButton(.closeButton) else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let originalX = close.frame.minX
        for type in types {
            guard let original = window.standardWindowButton(type),
                  let button = NSWindow.standardWindowButton(type, for: window.styleMask) else { continue }
            let offset = original.frame.minX - originalX
            let size = original.frame.size
            original.isHidden = true
            // Use AppKit's native button factory; moving the original lets the
            // titlebar layout reset its position on the next appearance update.
            button.target = window
            switch type {
            case .closeButton: button.action = #selector(NSWindow.performClose(_:))
            case .miniaturizeButton: button.action = #selector(NSWindow.performMiniaturize(_:))
            default: button.action = #selector(NSWindow.performZoom(_:))
            }
            button.isEnabled = original.isEnabled
            button.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(button, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18 + offset),
                button.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
                button.widthAnchor.constraint(equalToConstant: size.width),
                button.heightAnchor.constraint(equalToConstant: size.height)
            ])
        }
    }

    private func buildWindow() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        let main = NSView()
        sidebar.setAccessibilityIdentifier("exclusions.sidebar")
        main.setAccessibilityIdentifier("exclusions.content")
        sidebarSplit.isVertical = true
        sidebarSplit.dividerStyle = .thin
        sidebarSplit.delegate = self
        sidebarSplit.translatesAutoresizingMaskIntoConstraints = false
        sidebarSplit.setAccessibilityIdentifier("exclusions.sidebarSplit")
        sidebarSplit.setAccessibilityLabel(L("Exclusions sidebar", "Barre latérale des exclusions"))
        sidebarSplit.addArrangedSubview(sidebar)
        sidebarSplit.addArrangedSubview(main)
        sidebarSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        root.addSubview(sidebarSplit)
        NSLayoutConstraint.activate([
            sidebarSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sidebarSplit.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarSplit.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        root.layoutSubtreeIfNeeded()
        sidebarSplit.setPosition(initialSidebarWidth, ofDividerAt: 0)

        search.placeholderString = L("Search", "Rechercher")
        search.controlSize = .large
        search.focusRingType = .none
        search.isEditable = true
        search.isSelectable = true
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.backgroundColor = .clear
        search.font = .systemFont(ofSize: 16)
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.maximumNumberOfLines = 1
        search.cell?.usesSingleLineMode = true
        search.cell?.isScrollable = true
        search.cell?.wraps = false
        search.setAccessibilityIdentifier("exclusions.searchField")
        search.setAccessibilityLabel(L("Search exclusions", "Rechercher dans les exclusions"))
        search.translatesAutoresizingMaskIntoConstraints = false
        searchButton.title = L("Search", "Rechercher")
        searchButton.target = self
        searchButton.action = #selector(showSearch(_:))
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemBlue]))
        searchButton.image?.isTemplate = false
        searchButton.imagePosition = .imageLeading
        searchButton.alignment = .left
        searchButton.font = .systemFont(ofSize: 13)
        searchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchButton.isBordered = false
        searchButton.focusRingType = .none
        searchButton.drawsSelection = false
        searchButton.setButtonType(.momentaryPushIn)
        searchButton.setAccessibilityIdentifier("exclusions.searchButton")
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(searchButton)
        NSLayoutConstraint.activate([
            searchButton.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 46),
            searchButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            searchButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            searchButton.heightAnchor.constraint(equalToConstant: 32)
        ])
        let sidebarTitle = NSTextField(labelWithString: L("Exclusions", "Exclusions"))
        sidebarTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        sidebarTitle.textColor = .secondaryLabelColor
        sidebarTitle.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarTitle)
        NSLayoutConstraint.activate([
            sidebarTitle.topAnchor.constraint(equalTo: searchButton.bottomAnchor, constant: 16),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18)
        ])
        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 4
        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navigation)
        for item in ExclusionCategory.allCases {
            let button = ExclusionSidebarButton(title: item.sidebarTitle, target: self, action: #selector(selectCategory(_:)))
            button.tag = item.rawValue
            let symbol = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: item == .artists ? "mic" : "music.note", accessibilityDescription: nil)
            button.image = item == .albums ? albumSidebarIcon() : symbol?
                .withSymbolConfiguration(.init(paletteColors: [.systemBlue]))
            button.image?.isTemplate = false
            button.setAccessibilityLabel(item.sidebarTitle)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.font = .systemFont(ofSize: 13)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.isBordered = false
            button.setButtonType(.toggle)
            button.translatesAutoresizingMaskIntoConstraints = false
            navigation.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            sidebarButtons.append(button)
        }
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 6),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10)
        ])

        let optionsTitle = L("More options", "Plus d’options")
        let transferMenu = NSMenu(title: optionsTitle)
        transferMenu.autoenablesItems = false
        transferMenu.delegate = self
        let optionsItem = transferMenu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        optionsItem.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        let exportItem = AccessibleMenuItem(title: L("Export exclusions…", "Exporter les exclusions…"),
                                            action: #selector(exportExclusions(_:)), keyEquivalent: "")
        exportItem.target = self
        transferMenu.addItem(exportItem)
        let importItem = AccessibleMenuItem(title: L("Import exclusions…", "Importer les exclusions…"),
                                            action: #selector(importExclusions(_:)), keyEquivalent: "")
        importItem.target = self
        transferMenu.addItem(importItem)
        transferMenu.addItem(.separator())
        deleteAllItem.title = L("Delete all exclusions…", "Supprimer toutes les exclusions…")
        deleteAllItem.target = self
        deleteAllItem.action = #selector(deleteAllExclusions(_:))
        transferMenu.addItem(deleteAllItem)
        for item in [exportItem, importItem, deleteAllItem] {
            item.view = MenuActionRow(tint: .neutral, topRadius: 11, bottomRadius: 11,
                                      textColor: item === deleteAllItem ? .systemRed : nil)
        }
        sizeTransferMenu(transferMenu)
        transferOptionsButton.menu = transferMenu
        (transferOptionsButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        transferOptionsButton.setAccessibilityIdentifier("exclusions.transferOptionsButton")
        transferOptionsButton.setAccessibilityLabel(optionsTitle)
        transferOptionsButton.toolTip = optionsTitle
        transferOptionsButton.imagePosition = .imageOnly
        transferOptionsButton.imageScaling = .scaleProportionallyDown
        transferOptionsButton.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        transferOptionsButton.controlSize = .regular
        if #available(macOS 26.0, *) {
            transferOptionsButton.bezelStyle = .glass
            transferOptionsButton.borderShape = .circle
        } else {
            transferOptionsButton.bezelStyle = .circular
        }
        transferOptionsButton.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(transferOptionsButton)
        NSLayoutConstraint.activate([
            transferOptionsButton.widthAnchor.constraint(equalToConstant: 32),
            transferOptionsButton.heightAnchor.constraint(equalToConstant: 32),
            transferOptionsButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            transferOptionsButton.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16)
        ])

        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityIdentifier("exclusions.heading")
        main.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: main.topAnchor, constant: 28),
            heading.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -20),
            heading.heightAnchor.constraint(equalToConstant: 18)
        ])
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(body)
        bodyTop = body.topAnchor.constraint(equalTo: main.topAnchor, constant: 28)
        NSLayoutConstraint.activate([
            bodyTop!,
            body.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -12),
            body.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -14)
        ])
        configureArtistTable()
        configureSongTable()
        configureAlbums()
        for scroll in [artistScroll, albumScroll] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            body.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: body.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor)
            ])
        }
        songsContent.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(songsContent)
        NSLayoutConstraint.activate([
            songsContent.topAnchor.constraint(equalTo: body.topAnchor),
            songsContent.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: -12),
            songsContent.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: 12),
            songsContent.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.alignment = .center
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = .secondaryLabelColor
        emptyHint.alignment = .center
        emptyHint.maximumNumberOfLines = 3
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 7
        emptyView.addArrangedSubview(emptyLabel)
        emptyView.addArrangedSubview(emptyHint)
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: body.centerYAnchor, constant: -24),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -40),
            emptyHint.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])
        configureSearchCapsule(in: main)
    }

    // NSSplitView keeps native divider tracking, resize cursors and accessible
    // splitter controls. Only the sidebar width changes; the window stays fixed.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, minimumSidebarWidth)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, maximumSidebarWidth)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== splitView.arrangedSubviews.first
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        proposedEffectiveRect.union(drawnRect.insetBy(dx: -3, dy: 0))
    }

    private func albumSidebarIcon() -> NSImage? {
        AlbumIcon.image(side: 20, color: .systemBlue)
    }

    private func configureSearchCapsule(in main: NSView) {
        let frame = NSRect(x: 0, y: 0, width: 384, height: 52)
        let content = ExclusionSearchContentView(frame: frame)
        content.autoresizingMask = [.width, .height]
        content.onBackgroundClick = { [weak self] in self?.focusSearch(selectAll: false) }
        let capsule: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.tintColor = .white.withAlphaComponent(0.18)
            glass.cornerRadius = 26
            glass.contentView = content
            capsule = glass
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .followsWindowActiveState
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 26
            effect.layer?.masksToBounds = true
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            effect.addSubview(content)
            capsule = effect
        }
        searchMagnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        searchMagnifier.imageScaling = .scaleProportionallyDown
        searchMagnifier.contentTintColor = .secondaryLabelColor
        searchMagnifier.setAccessibilityElement(false)
        searchMagnifier.setAccessibilityIdentifier("exclusions.searchMagnifier")
        searchClearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        searchClearButton.imagePosition = .imageOnly
        searchClearButton.imageScaling = .scaleProportionallyDown
        searchClearButton.contentTintColor = .secondaryLabelColor
        searchClearButton.isBordered = false
        searchClearButton.focusRingType = .none
        searchClearButton.setButtonType(.momentaryPushIn)
        searchClearButton.target = self
        searchClearButton.action = #selector(clearSearch(_:))
        searchClearButton.setAccessibilityIdentifier("exclusions.searchClearButton")
        searchClearButton.setAccessibilityLabel(L("Clear search", "Effacer la recherche"))
        searchClearButton.toolTip = L("Clear search", "Effacer la recherche")
        for view in [searchMagnifier, search, searchClearButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchMagnifier.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            searchMagnifier.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            searchMagnifier.widthAnchor.constraint(equalToConstant: 20),
            searchMagnifier.heightAnchor.constraint(equalToConstant: 20),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 46),
            search.trailingAnchor.constraint(equalTo: searchClearButton.leadingAnchor, constant: -8),
            search.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 2),
            search.heightAnchor.constraint(equalToConstant: 22),
            searchClearButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            searchClearButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            searchClearButton.widthAnchor.constraint(equalToConstant: 20),
            searchClearButton.heightAnchor.constraint(equalToConstant: 20)
        ])
        capsule.setAccessibilityIdentifier("exclusions.searchCapsule")
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.isHidden = true
        main.addSubview(capsule, positioned: .above, relativeTo: nil)
        searchCapsuleTop = capsule.topAnchor.constraint(equalTo: main.topAnchor, constant: 90)
        let preferredWidth = capsule.widthAnchor.constraint(equalToConstant: 384)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
            capsule.widthAnchor.constraint(lessThanOrEqualTo: main.widthAnchor, constant: -32),
            capsule.heightAnchor.constraint(equalToConstant: 52),
            capsule.centerXAnchor.constraint(equalTo: main.centerXAnchor),
            searchCapsuleTop!
        ])
        searchCapsule = capsule
    }

    private func configureArtistTable() {
        let column = NSTableColumn(identifier: .init("artistName"))
        column.resizingMask = .autoresizingMask
        artistTable.addTableColumn(column)
        artistTable.headerView = nil
        artistTable.style = .plain
        artistTable.allowsMultipleSelection = false
        artistTable.allowsEmptySelection = true
        artistTable.rowHeight = 46
        artistTable.intercellSpacing = NSSize(width: 0, height: 0)
        artistTable.gridStyleMask = []
        artistTable.backgroundColor = .clear
        artistTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        artistTable.dataSource = self
        artistTable.delegate = self
        artistTable.contextMenuForRow = { [weak self] row in self?.contextMenu(for: row) }
        artistScroll.documentView = artistTable
    }

    private func configureSongTable() {
        for (table, scroll, prefix) in [(recentSongTable, recentSongScroll as NSScrollView, "recent"),
                                        (songTable, songScroll, "all")] {
            for (key, label, width, minimum) in [("title", L("Title", "Titre"), 280.0, 160.0),
                                               ("artist", L("Artist", "Artiste"), 179.0, 100.0)] {
                let column = NSTableColumn(identifier: .init(key))
                column.title = label
                column.width = width
                column.minWidth = minimum
                table.addTableColumn(column)
            }
            table.style = .plain
            table.allowsMultipleSelection = false
            table.allowsEmptySelection = true
            table.headerView = nil
            table.rowHeight = 22
            table.intercellSpacing = .zero
            table.gridStyleMask = []
            table.backgroundColor = .clear
            table.usesAlternatingRowBackgroundColors = false
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            table.setAccessibilityIdentifier("exclusions.songs.\(prefix)Table")
            table.contextMenuForRow = { [weak self, weak table] row in
                guard let self, let table, let rule = self.songRule(in: table, row: row) else { return nil }
                return self.ruleMenu(id: rule.id)
            }
            scroll.automaticallyAdjustsContentInsets = false
            scroll.hasVerticalScroller = table === songTable
            scroll.hasHorizontalScroller = false
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
            scroll.setAccessibilityIdentifier("exclusions.songs.\(prefix)Scroll")
            scroll.documentView = table
        }
        for (label, identifier) in [(recentSongHeading, "recentHeading"), (allSongHeading, "allHeading")] {
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityIdentifier("exclusions.songs.\(identifier)")
        }
        recentSongNote.font = .systemFont(ofSize: 11)
        recentSongNote.textColor = .secondaryLabelColor
        recentSongNote.lineBreakMode = .byTruncatingTail
        recentSongNote.setAccessibilityIdentifier("exclusions.songs.recentEmpty")
        for (label, identifier) in [(recentSongCount, "recentCount"), (songCount, "count")] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityIdentifier("exclusions.songs.\(identifier)")
        }
        let recentColumns = ExclusionColumnHeaderView(table: recentSongTable)
        let allColumns = ExclusionColumnHeaderView(table: songTable, onSort: { [weak self] key in
            self?.sortSongs(by: key)
        })
        songColumnsHeader = allColumns
        recentColumns.setAccessibilityIdentifier("exclusions.songs.recentColumns")
        allColumns.setAccessibilityIdentifier("exclusions.songs.allColumns")
        songFade.setAccessibilityIdentifier("exclusions.songs.topFade")
        for view in [recentSongHeading, recentSongCount, recentColumns, recentSongScroll, recentSongNote,
                     allSongHeading, songCount, allColumns, songScroll, songFade] {
            view.translatesAutoresizingMaskIntoConstraints = false
            songsContent.addSubview(view)
        }
        recentSongHeight = recentSongScroll.heightAnchor.constraint(equalToConstant: 66)
        NSLayoutConstraint.activate([
            recentSongHeading.topAnchor.constraint(equalTo: songsContent.topAnchor),
            recentSongHeading.leadingAnchor.constraint(equalTo: songsContent.leadingAnchor, constant: 20),
            recentSongHeading.trailingAnchor.constraint(equalTo: songsContent.trailingAnchor, constant: -20),
            recentSongHeading.heightAnchor.constraint(equalToConstant: 18),
            recentSongCount.topAnchor.constraint(equalTo: recentSongHeading.bottomAnchor, constant: 1),
            recentSongCount.leadingAnchor.constraint(equalTo: recentSongHeading.leadingAnchor),
            recentSongCount.trailingAnchor.constraint(equalTo: recentSongHeading.trailingAnchor),
            recentSongCount.heightAnchor.constraint(equalToConstant: 15),
            recentColumns.topAnchor.constraint(equalTo: recentSongCount.bottomAnchor, constant: 10),
            recentColumns.leadingAnchor.constraint(equalTo: songsContent.leadingAnchor),
            recentColumns.trailingAnchor.constraint(equalTo: songsContent.trailingAnchor),
            recentColumns.heightAnchor.constraint(equalToConstant: 24),
            recentSongScroll.topAnchor.constraint(equalTo: recentColumns.bottomAnchor),
            recentSongScroll.leadingAnchor.constraint(equalTo: songsContent.leadingAnchor),
            recentSongScroll.trailingAnchor.constraint(equalTo: songsContent.trailingAnchor),
            recentSongHeight!,
            recentSongNote.leadingAnchor.constraint(equalTo: recentSongScroll.leadingAnchor, constant: 20),
            recentSongNote.trailingAnchor.constraint(equalTo: recentSongScroll.trailingAnchor, constant: -20),
            recentSongNote.centerYAnchor.constraint(equalTo: recentSongScroll.centerYAnchor),
            allSongHeading.topAnchor.constraint(equalTo: recentSongScroll.bottomAnchor, constant: 24),
            allSongHeading.leadingAnchor.constraint(equalTo: recentSongHeading.leadingAnchor),
            allSongHeading.trailingAnchor.constraint(equalTo: songsContent.trailingAnchor, constant: -20),
            allSongHeading.heightAnchor.constraint(equalToConstant: 18),
            songCount.topAnchor.constraint(equalTo: allSongHeading.bottomAnchor, constant: 1),
            songCount.leadingAnchor.constraint(equalTo: allSongHeading.leadingAnchor),
            songCount.trailingAnchor.constraint(equalTo: allSongHeading.trailingAnchor),
            songCount.heightAnchor.constraint(equalToConstant: 15),
            allColumns.topAnchor.constraint(equalTo: songCount.bottomAnchor, constant: 10),
            allColumns.leadingAnchor.constraint(equalTo: songsContent.leadingAnchor),
            allColumns.trailingAnchor.constraint(equalTo: songsContent.trailingAnchor),
            allColumns.heightAnchor.constraint(equalToConstant: 24),
            songScroll.topAnchor.constraint(equalTo: allColumns.bottomAnchor),
            songScroll.leadingAnchor.constraint(equalTo: songsContent.leadingAnchor),
            songScroll.trailingAnchor.constraint(equalTo: songsContent.trailingAnchor),
            songScroll.bottomAnchor.constraint(equalTo: songsContent.bottomAnchor),
            songFade.topAnchor.constraint(equalTo: songScroll.topAnchor),
            songFade.leadingAnchor.constraint(equalTo: songScroll.leadingAnchor),
            songFade.trailingAnchor.constraint(equalTo: songScroll.trailingAnchor),
            songFade.heightAnchor.constraint(equalToConstant: 10)
        ])
        songScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(songScrollChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: songScroll.contentView)
        songFade.isHidden = true
    }

    @objc private func songScrollChanged(_ notification: Notification) {
        songFade.isHidden = category != .songs || songScroll.contentView.bounds.minY <= 0.5
    }

    private func songRule(in table: NSTableView, row: Int) -> BanRule? {
        guard category == .songs, table === recentSongTable || table === songTable else { return nil }
        let entries = table === recentSongTable ? recentSongRules : visibleRules
        return entries.indices.contains(row) ? entries[row] : nil
    }

    private func sortSongs(by key: String) {
        guard key == "title" || key == "artist" else { return }
        if songSortKey == key { songSortAscending.toggle() }
        else { songSortKey = key; songSortAscending = true }
        reloadContent()
        songScroll.contentView.scroll(to: .zero)
        songScroll.reflectScrolledClipView(songScroll.contentView)
        songScrollChanged(Notification(name: NSView.boundsDidChangeNotification))
    }

    private func songPrecedes(_ lhs: BanRule, _ rhs: BanRule) -> Bool {
        let left = songSortKey == "artist" ? [lhs.artist ?? "", lhs.name] : [lhs.name, lhs.artist ?? ""]
        let right = songSortKey == "artist" ? [rhs.artist ?? "", rhs.name] : [rhs.name, rhs.artist ?? ""]
        for (a, b) in zip(left + [lhs.album ?? "", lhs.id.uuidString], right + [rhs.album ?? "", rhs.id.uuidString]) {
            let order = a.localizedStandardCompare(b)
            if order != .orderedSame {
                return songSortAscending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        return false
    }

    private func configureAlbums() {
        albumScroll.automaticallyAdjustsContentInsets = false
        albums.collectionViewLayout = ExclusionAlbumGridLayout()
        albums.register(ExclusionAlbumItem.self, forItemWithIdentifier: .init("album"))
        albums.register(ExclusionAlbumHeader.self,
                        forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                        withIdentifier: .init("albumHeader"))
        albums.dataSource = self
        albums.delegate = self
        albums.backgroundColors = [.clear]
        albums.isSelectable = true
        albums.allowsMultipleSelection = false
        albums.frame = albumScroll.contentView.bounds
        albums.autoresizingMask = [.width]
        albums.contextMenuForItem = { [weak self] index in
            guard let self, self.albumSections.indices.contains(index.section),
                  self.albumSections[index.section].indices.contains(index.item) else { return nil }
            self.clearSelection(except: self.albums)
            return self.ruleMenu(id: self.albumSections[index.section][index.item].id)
        }
        albumScroll.documentView = albums
    }

    private func reloadContent() {
        guard window?.contentView != nil else { return }
        // Row indexes can refer to different rules after a search or reload.
        clearSelection()
        deleteAllItem.isEnabled = !rules.isEmpty
        deleteAllItem.attributedTitle = NSAttributedString(string: deleteAllItem.title,
            attributes: [.font: NSFont.menuFont(ofSize: 0),
                         .foregroundColor: rules.isEmpty ? NSColor.disabledControlTextColor : NSColor.systemRed])
        deleteAllItem.view?.needsDisplay = true
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchClearButton.isHidden = search.stringValue.isEmpty
        let matchesQuery: (BanRule) -> Bool = { rule in
            query.isEmpty || [rule.name, rule.artist ?? "", rule.album ?? ""]
                .contains(where: { $0.localizedStandardContains(query) })
        }
        // Choose the three identities before searching, so an older match can
        // never replace a recent item that does not match the current query.
        let recent = rules.filter { $0.kind == category.kind }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(3).filter(matchesQuery)
        visibleRules = rules.filter { rule in
            rule.kind == category.kind && matchesQuery(rule)
        }.sorted {
            if category == .songs { return songPrecedes($0, $1) }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? ($0.artist ?? "").localizedStandardCompare($1.artist ?? "") == .orderedAscending : order == .orderedAscending
        }
        recentSongRules = category == .songs ? Array(recent) : []
        albumSections = category == .albums && !visibleRules.isEmpty ? [Array(recent), visibleRules] : []
        recentSongHeight?.constant = recentSongRules.isEmpty ? 30 : CGFloat(recentSongRules.count) * recentSongTable.rowHeight
        recentSongNote.isHidden = !recentSongRules.isEmpty
        let recentCount = recentSongRules.count
        recentSongCount.stringValue = recentCount == 1 ? L("1 song", "1 morceau") : L("\(recentCount) songs", "\(recentCount) morceaux")
        let count = visibleRules.count
        songCount.stringValue = count == 1 ? L("1 song", "1 morceau") : L("\(count) songs", "\(count) morceaux")
        songColumnsHeader?.setSort(key: songSortKey, ascending: songSortAscending)
        heading.stringValue = query.isEmpty ? category.title
            : L("Results (\(visibleRules.count))", "Résultats (\(visibleRules.count))")
        heading.isHidden = category != .artists
        switch category {
        case .artists: bodyTop?.constant = 58
        case .songs: bodyTop?.constant = 18
        case .albums: bodyTop?.constant = 22
        }
        heading.toolTip = query.isEmpty ? nil : L("Search: \(query)", "Recherche : \(query)")
        searchButton.toolTip = heading.toolTip
        searchButton.title = query.isEmpty ? L("Search", "Rechercher")
            : L("Search: \(query)", "Recherche : \(query)")
        searchButton.setAccessibilityLabel(L("Search", "Rechercher"))
        searchButton.setAccessibilityValue(query)
        searchButton.needsDisplay = true
        for button in sidebarButtons { button.state = button.tag == category.rawValue ? .on : .off; button.needsDisplay = true }
        artistTable.reloadData()
        songTable.reloadData()
        recentSongTable.reloadData()
        recentSongScroll.contentView.scroll(to: .zero)
        songScrollChanged(Notification(name: NSView.boundsDidChangeNotification))
        albums.reloadData()
        albums.collectionViewLayout?.invalidateLayout()
        let empty = visibleRules.isEmpty
        artistScroll.isHidden = category != .artists || empty
        songsContent.isHidden = category != .songs || empty
        albumScroll.isHidden = category != .albums || empty
        emptyView.isHidden = !empty
        emptyLabel.stringValue = query.isEmpty
            ? category.emptyTitle
            : L("No results", "Aucun résultat")
        emptyHint.stringValue = query.isEmpty
            ? L("Exclusions from the menu bar appear here.", "Les exclusions ajoutées depuis la barre de menus apparaissent ici.")
            : L("Try another name or title.", "Essayez un autre nom ou titre.")
        scheduleSearchPlacement()
    }

    private func scheduleSearchPlacement() {
        searchPlacementWork?.cancel()
        guard let capsule = searchCapsule, !capsule.isHidden else { return }
        // Let results settle before moving the editor, rather than chasing
        // every keystroke. Dismissal or another reload cancels this placement.
        let work = DispatchWorkItem { [weak self] in self?.positionSearchCapsule(animated: true) }
        searchPlacementWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func positionSearchCapsule(animated: Bool) {
        guard let capsule = searchCapsule, !capsule.isHidden,
              let main = capsule.superview, let top = searchCapsuleTop else { return }
        main.layoutSubtreeIfNeeded()
        var target: CGFloat = 90
        if !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let contentBottom: CGFloat
            func viewTop(_ view: NSView) -> CGFloat {
                main.bounds.maxY - main.convert(view.bounds, from: view).maxY
            }
            if visibleRules.isEmpty {
                contentBottom = viewTop(emptyView) + emptyView.bounds.height
            } else {
                switch category {
                case .artists:
                    contentBottom = viewTop(artistScroll) + CGFloat(visibleRules.count) * artistTable.rowHeight
                case .songs:
                    contentBottom = viewTop(songScroll) + CGFloat(visibleRules.count) * songTable.rowHeight
                case .albums:
                    contentBottom = viewTop(albumScroll)
                        + ((albums.collectionViewLayout as? ExclusionAlbumGridLayout)?.resultsHeight ?? main.bounds.height)
                }
            }
            // Use only genuinely empty space below the complete result set;
            // scrolling a long list must not make the capsule cover its rows.
            let firstFreeTop = max(90, contentBottom + 20)
            let lastFreeTop = main.bounds.height - 20 - capsule.bounds.height
            if firstFreeTop <= lastFreeTop {
                target = ((firstFreeTop + lastFreeTop) / 2).rounded()
            }
        }
        guard abs(top.constant - target) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.28 : 0
            context.allowsImplicitAnimation = context.duration > 0
            top.constant = target
            main.layoutSubtreeIfNeeded()
        }
    }

    func controlTextDidChange(_ obj: Notification) { reloadContent() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        dismissSearch(restoreFocus: true)
        return true
    }

    func windowWillClose(_ notification: Notification) { dismissSearch() }
    func windowDidResignKey(_ notification: Notification) { dismissSearch() }
    func windowWillMiniaturize(_ notification: Notification) { dismissSearch() }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === artistTable { return category == .artists ? visibleRules.count : 0 }
        guard category == .songs else { return 0 }
        return tableView === recentSongTable ? recentSongRules.count : visibleRules.count
    }

    private func clearSelection(except activeView: NSView? = nil) {
        for table in [artistTable, recentSongTable, songTable]
            where table !== activeView && !table.selectedRowIndexes.isEmpty {
            table.deselectAll(nil)
        }
        if albums !== activeView, !albums.selectionIndexPaths.isEmpty {
            albums.deselectItems(at: albums.selectionIndexPaths)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table.selectedRow >= 0,
              table === artistTable || table === recentSongTable || table === songTable else { return }
        // The recent and complete lists are one selection surface. Empty
        // notifications from clearing a sibling must not clear the new row.
        clearSelection(except: table)
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard collectionView === albums, !indexPaths.isEmpty else { return }
        clearSelection(except: collectionView)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === artistTable || songRule(in: tableView, row: row) != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === artistTable ? 46 : 22
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if tableView === artistTable { return ExclusionArtistRowView() }
        guard songRule(in: tableView, row: row) != nil else { return nil }
        let view = ExclusionSongRowView()
        view.isLightBand = !row.isMultiple(of: 2)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule: BanRule
        if tableView === artistTable {
            guard visibleRules.indices.contains(row) else { return nil }
            rule = visibleRules[row]
            let id = NSUserInterfaceItemIdentifier("artistCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ExclusionArtistCell) ?? ExclusionArtistCell()
            cell.identifier = id
            cell.name.stringValue = rule.name
            cell.name.toolTip = rule.name
            requestArtwork(for: rule, in: cell.artwork)
            return cell
        }
        guard let song = songRule(in: tableView, row: row), let key = tableColumn?.identifier.rawValue else { return nil }
        rule = song
        let id = NSUserInterfaceItemIdentifier("song_" + key)
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ExclusionTextCell) ?? ExclusionTextCell()
        cell.identifier = id
        let value = key == "title" ? rule.name : (key == "artist" ? rule.artist ?? "" : rule.album ?? "")
        cell.label.stringValue = value
        cell.label.toolTip = value
        cell.leadingInset.constant = key == "title" ? 20 : 8
        cell.normalTextColor = .labelColor
        return cell
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        category == .albums ? albumSections.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        category == .albums && albumSections.indices.contains(section) ? albumSections[section].count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("album"), for: indexPath) as! ExclusionAlbumItem
        let rule = albumSections[indexPath.section][indexPath.item]
        item.configure(rule: rule)
        requestArtwork(for: rule, in: item.artwork)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: .init("albumHeader"),
                                                          for: indexPath) as! ExclusionAlbumHeader
        header.title.setAccessibilityIdentifier(indexPath.section == 0
            ? "exclusions.albums.recentHeading" : "exclusions.albums.allHeading")
        header.title.stringValue = indexPath.section == 0
            ? L("Recently excluded albums", "Albums exclus récemment") : L("Excluded albums", "Albums exclus")
        header.note.stringValue = L("No recent albums match your search.", "Aucun album récent ne correspond à votre recherche.")
        header.note.isHidden = !albumSections[indexPath.section].isEmpty
        return header
    }

    private func requestArtwork(for rule: BanRule, in view: ExclusionArtworkView) {
        view.ruleID = rule.id
        view.artwork = artworkCache[rule.id]
        view.isCircular = rule.kind == .artist
        view.placeholderKind = rule.kind
        view.needsDisplay = true
        guard view.artwork == nil, let loadArtwork else { return }
        let id = rule.id
        loadArtwork(rule) { [weak self, weak view] image in
            DispatchQueue.main.async {
                guard let self, self.rules.contains(where: { $0.id == id }) else { return }
                if let image { self.artworkCache[id] = image }
                guard let view, view.ruleID == id else { return }
                view.artwork = image
                view.needsDisplay = true
            }
        }
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        guard category == .artists, visibleRules.indices.contains(row) else { return nil }
        return ruleMenu(id: visibleRules[row].id)
    }

    private func ruleMenu(id: UUID) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: L("Remove exclusion", "Retirer l’exclusion"), action: #selector(unblock(_:)), keyEquivalent: "")
        item.representedObject = id
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func selectCategory(_ sender: NSButton) {
        guard let category = ExclusionCategory(rawValue: sender.tag) else { return }
        self.category = category
        reloadContent()
    }

    @objc private func searchChanged(_ sender: NSTextField) { reloadContent() }

    @objc private func clearSearch(_ sender: NSButton) {
        if let editor = search.currentEditor() as? NSTextView {
            editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }
        search.stringValue = ""
        reloadContent()
        focusSearch(selectAll: false)
    }

    @objc private func showSearch(_ sender: NSButton) {
        guard let capsule = searchCapsule else { return }
        if !capsule.isHidden { dismissSearch(restoreFocus: true); return }
        capsule.isHidden = false
        capsule.superview?.layoutSubtreeIfNeeded()
        scheduleSearchPlacement()
        installSearchDismissMonitor()
        focusSearch(selectAll: true)
    }

    private func focusSearch(selectAll: Bool) {
        guard let capsule = searchCapsule, !capsule.isHidden, let window else { return }
        window.makeFirstResponder(search)
        if selectAll { search.selectText(nil) }
    }

    private func dismissSearch(restoreFocus: Bool = false) {
        searchPlacementWork?.cancel()
        searchPlacementWork = nil
        if let searchDismissMonitor {
            NSEvent.removeMonitor(searchDismissMonitor)
            self.searchDismissMonitor = nil
        }
        if search.currentEditor() != nil {
            window?.makeFirstResponder(restoreFocus ? searchButton : nil)
        }
        searchCapsule?.isHidden = true
        searchCapsuleTop?.constant = 90
    }

    private func installSearchDismissMonitor() {
        guard searchDismissMonitor == nil else { return }
        searchDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let keepEvent = MainActor.assumeIsolated { self?.handleSearchEvent(event) ?? true }
            return keepEvent ? event : nil
        }
    }

    private func handleSearchEvent(_ event: NSEvent) -> Bool {
        guard let capsule = searchCapsule, !capsule.isHidden else { return true }
        if event.type == .keyDown {
            if event.keyCode == 53 { dismissSearch(restoreFocus: true); return false }
            return true
        }
        guard event.window === window else { dismissSearch(); return true }
        let point = event.locationInWindow
        if capsule.bounds.contains(capsule.convert(point, from: nil)) { return true }
        // The sidebar action owns its toggle; hiding here would let
        // its subsequent action reopen the capsule on the same click.
        if searchButton.bounds.contains(searchButton.convert(point, from: nil)) { return true }
        dismissSearch()
        return true
    }

    @objc private func unblock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onUnblock?(id)
    }

}

@MainActor
private final class ExclusionSearchContentView: NSView {
    var onBackgroundClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }
}

@MainActor
private enum ExclusionSongColors {
    static var bands: [NSColor] {
        let base = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) ?? .black
        // In dark appearance AppKit supplies one band as translucent white.
        // Resolve it against the table background before ordering the bands.
        return NSColor.alternatingContentBackgroundColors.map { color in
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
            let alpha = rgb.alphaComponent
            return NSColor(deviceRed: rgb.redComponent * alpha + base.redComponent * (1 - alpha),
                           green: rgb.greenComponent * alpha + base.greenComponent * (1 - alpha),
                           blue: rgb.blueComponent * alpha + base.blueComponent * (1 - alpha), alpha: 1)
        }.sorted { luminance($0) < luminance($1) }
    }
    static var darker: NSColor { bands.first ?? .windowBackgroundColor }
    static var lighter: NSColor { bands.last ?? .textBackgroundColor }
    // Light appearance uses a white canvas with gray bands; dark
    // appearance keeps the darker canvas and its lighter bands.
    private static var usesLightAppearance: Bool { luminance(.textBackgroundColor) > 0.5 }
    static var background: NSColor { usesLightAppearance ? lighter : darker }
    static var stripe: NSColor { usesLightAppearance ? darker : lighter }
    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        return rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722
    }
}

@MainActor
private final class ExclusionColumnHeaderView: NSView {
    private weak var table: NSTableView?
    private let onSort: ((String) -> Void)?
    private var buttons: [ExclusionSortHeaderButton] = []
    override var isFlipped: Bool { true }

    init(table: NSTableView, onSort: ((String) -> Void)? = nil) {
        self.table = table
        self.onSort = onSort
        super.init(frame: .zero)
        setAccessibilityElement(false)
        for (index, column) in table.tableColumns.enumerated() {
            let button = ExclusionSortHeaderButton(title: column.title, target: self, action: #selector(sortColumn(_:)))
            button.identifier = column.identifier
            button.tag = index
            button.textInset = index == 0 ? 20 : 8
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.isEnabled = onSort != nil
            button.setAccessibilityLabel(column.title)
            button.setAccessibilityIdentifier("exclusions.songs.\(onSort == nil ? "recent" : "all").sort.\(column.identifier.rawValue)")
            if onSort == nil { button.setAccessibilityRole(.staticText) }
            addSubview(button)
            buttons.append(button)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged(_:)),
            name: NSTableView.columnDidResizeNotification, object: table)
    }
    required init?(coder: NSCoder) { nil }

    func setSort(key: String, ascending: Bool) {
        for button in buttons {
            let selected = button.identifier?.rawValue == key
            button.sortAscending = selected ? ascending : nil
            button.setAccessibilityValue(selected ? L(ascending ? "Ascending" : "Descending", ascending ? "Croissant" : "Décroissant") : "")
            button.setAccessibilityHelp(L("Sort by \(button.title). Activate again to reverse the order.",
                                           "Trier par \(button.title.lowercased()). Activez à nouveau pour inverser l’ordre."))
            button.needsDisplay = true
        }
    }

    @objc private func sortColumn(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        onSort?(key)
    }
    @objc private func columnsChanged(_ notification: Notification) { needsLayout = true }

    override func layout() {
        super.layout()
        guard let table else { return }
        for (index, button) in buttons.enumerated() {
            let column = table.rect(ofColumn: index)
            button.frame = NSRect(x: column.minX, y: 0, width: column.width, height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ExclusionSongColors.stripe.setFill()
        bounds.fill()
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - pixel, width: bounds.width, height: pixel).fill()
        for button in buttons.dropFirst() {
            NSRect(x: button.frame.minX, y: 3, width: pixel, height: bounds.height - 6).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        buttons.forEach { $0.needsDisplay = true }
    }
}

@MainActor
private final class ExclusionSortHeaderButton: NSButton {
    var textInset: CGFloat = 8
    var sortAscending: Bool?

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: sortAscending == nil ? .regular : .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: textInset, y: bounds.midY - height / 2,
            width: max(0, bounds.width - textInset - 22), height: height), withAttributes: attributes)
        if let ascending = sortAscending,
           let image = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) {
            let rect = NSRect(x: bounds.maxX - 15, y: bounds.midY - 4, width: 8, height: 8)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.7,
                       respectFlipped: true, hints: nil)
        }
    }
}

@MainActor
private final class ExclusionFixedScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = ExclusionFixedClipView()
    }
    required init?(coder: NSCoder) { nil }
    override func scrollWheel(with event: NSEvent) {}
}

@MainActor
private final class ExclusionFixedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        result.origin = .zero
        return result
    }
}

@MainActor
private final class ExclusionScrollFadeView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let color = ExclusionSongColors.background
        NSGradient(starting: color, ending: color.withAlphaComponent(0))?
            .draw(from: NSPoint(x: bounds.midX, y: bounds.minY),
                  to: NSPoint(x: bounds.midX, y: bounds.maxY), options: [])
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private enum ExclusionCategory: Int, CaseIterable {
    case artists, albums, songs
    var kind: BanRule.Kind { switch self { case .artists: .artist; case .albums: .album; case .songs: .track } }
    var title: String { switch self { case .artists: L("Artists", "Artistes"); case .albums: L("Albums", "Albums"); case .songs: L("Songs", "Morceaux") } }
    var sidebarTitle: String { switch self {
    case .artists: L("Excluded artists", "Artistes exclus")
    case .albums: L("Excluded albums", "Albums exclus")
    case .songs: L("Excluded songs", "Morceaux exclus")
    } }
    var symbol: String { switch self { case .artists: "music.mic"; case .albums: "person.crop.square"; case .songs: "music.note" } }
    var emptyTitle: String { switch self {
    case .artists: L("No excluded artists", "Aucun artiste exclu")
    case .albums: L("No excluded albums", "Aucun album exclu")
    case .songs: L("No excluded songs", "Aucun morceau exclu")
    } }
}

@MainActor
private final class ExclusionSidebarButton: NSButton {
    var drawsSelection = true
    override func draw(_ dirtyRect: NSRect) {
        if drawsSelection && state == .on {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        // Draw the title explicitly so NSButton's toggle tint cannot turn it
        // blue or dim it when the window is inactive. Only the symbol is blue.
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(20 / image.size.width, 20 / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: 9 + (20 - size.width) / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: drawsSelection && state == .on ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 36, y: bounds.midY - height / 2,
                                          width: max(0, bounds.width - 44), height: height), withAttributes: attributes)
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
}

@MainActor
private class ExclusionSelectedRowView: NSTableRowView {
    private let nativeSelection = PassThroughSelectionView()
    private var maskSize = NSSize.zero
    var fullWidthSelection: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nativeSelection.material = .selection
        nativeSelection.blendingMode = .withinWindow
        nativeSelection.state = .active
        nativeSelection.isEmphasized = true
        nativeSelection.isHidden = true
        nativeSelection.setAccessibilityElement(false)
        nativeSelection.autoresizingMask = [.width, .height]
        nativeSelection.frame = bounds
        addSubview(nativeSelection, positioned: .below, relativeTo: nil)
        updateSelectionEffect()
    }

    required init?(coder: NSCoder) { nil }

    override var isSelected: Bool {
        didSet {
            updateSelectionEffect()
            needsDisplay = true
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    // AppKit may add or reuse cell views after constructing the row. Keep only
    // our material behind them, without changing their event or AX behavior.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== nativeSelection, nativeSelection.superview === self,
              subviews.first !== nativeSelection else { return }
        addSubview(nativeSelection, positioned: .below, relativeTo: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSelectionEffect()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSelectionEffect()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // The semantic material supplies the system selection color. Drawing
        // a second flat selection here would obscure that native effect.
        updateSelectionEffect()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        nativeSelection.needsDisplay = true
        needsDisplay = true
    }

    private func updateSelectionEffect() {
        nativeSelection.frame = bounds
        if fullWidthSelection {
            nativeSelection.maskImage = nil
        } else if maskSize != bounds.size {
            maskSize = bounds.size
            if bounds.width > 4, bounds.height > 2 {
                let rect = NSRect(origin: .zero, size: bounds.size).insetBy(dx: 2, dy: 1)
                let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
                nativeSelection.maskImage = NSImage(size: bounds.size, flipped: isFlipped) { _ in
                    NSColor.white.setFill()
                    path.fill()
                    return true
                }
            } else {
                nativeSelection.maskImage = nil
            }
        }
        let visible = isSelected && bounds.width > 4 && bounds.height > 2
        if nativeSelection.isHidden == visible { nativeSelection.isHidden = !visible }
    }

    private final class PassThroughSelectionView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
private final class ExclusionArtistRowView: ExclusionSelectedRowView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !isSelected else { return }
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let y = isFlipped ? bounds.maxY - pixel : bounds.minY
        NSColor.separatorColor.setFill()
        NSRect(x: 50, y: y, width: max(0, bounds.width - 56), height: pixel).fill()
    }
}

@MainActor
private final class ExclusionSongRowView: ExclusionSelectedRowView {
    override var fullWidthSelection: Bool { true }
    var isLightBand = true {
        didSet { if oldValue != isLightBand { needsDisplay = true } }
    }
    override func drawBackground(in dirtyRect: NSRect) {
        ExclusionSongColors.background.setFill()
        bounds.fill()
        guard isLightBand else { return }
        ExclusionSongColors.stripe.setFill()
        bounds.fill()
    }
}

@MainActor
private final class ExclusionArtistCell: NSTableCellView {
    let artwork = ExclusionArtworkView()
    let name = NSTextField(labelWithString: "")
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            name.textColor = selected ? .white : .labelColor
            artwork.isSelectionEmphasized = selected
        }
    }
    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [artwork, name] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), artwork.centerYAnchor.constraint(equalTo: centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 32), artwork.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ExclusionTextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private(set) var leadingInset: NSLayoutConstraint!
    var normalTextColor = NSColor.labelColor { didSet { updateTextColor() } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateTextColor() } }

    private func updateTextColor() {
        label.textColor = backgroundStyle == .emphasized ? .white : normalTextColor
    }
    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        leadingInset = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
        NSLayoutConstraint.activate([
            leadingInset,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ExclusionAlbumItem: NSCollectionViewItem {
    let artwork = ExclusionArtworkView()
    let titleLabel = NSTextField(labelWithString: "")
    let artistLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        for view in [artwork, titleLabel, artistLabel] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: root.topAnchor), artwork.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: root.trailingAnchor), artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor),
            titleLabel.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: 7), titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3), artistLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        view = root
    }

    func configure(rule: BanRule) {
        _ = view
        titleLabel.stringValue = rule.name
        titleLabel.toolTip = rule.name
        artistLabel.stringValue = rule.artist ?? ""
        artistLabel.toolTip = rule.artist
    }

    override var isSelected: Bool {
        didSet { titleLabel.textColor = isSelected ? .selectedContentBackgroundColor : .labelColor }
    }
}

@MainActor
private final class ExclusionAlbumHeader: NSView {
    let title = NSTextField(labelWithString: "")
    let note = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        for label in [title, note] { label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.heightAnchor.constraint(equalToConstant: 18),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ExclusionArtworkView: NSView {
    var ruleID: UUID?
    var artwork: NSImage?
    var isCircular = false
    var placeholderKind: BanRule.Kind = .album
    var isSelectionEmphasized = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let radius: CGFloat = isCircular ? min(bounds.width, bounds.height) / 2 : 6
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        shape.addClip()
        let background = isSelectionEmphasized ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        background.setFill()
        shape.fill()
        if let artwork, artwork.size.width > 0, artwork.size.height > 0, bounds.width > 0, bounds.height > 0 {
            let targetAspect = bounds.width / bounds.height
            let sourceAspect = artwork.size.width / artwork.size.height
            var source = NSRect(origin: .zero, size: artwork.size)
            if sourceAspect > targetAspect {
                source.size.width = source.height * targetAspect
                source.origin.x = (artwork.size.width - source.width) / 2
            } else {
                source.size.height = source.width / targetAspect
                source.origin.y = (artwork.size.height - source.height) / 2
            }
            artwork.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let size = min(44, bounds.width * 0.4)
            let color: NSColor = isSelectionEmphasized ? .white : .tertiaryLabelColor
            let image = placeholderKind == .album ? AlbumIcon.image(side: size, color: color)
                : NSImage(systemSymbolName: placeholderKind == .artist ? "person.fill" : "music.note", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [color]))
            image?.draw(in: NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size))
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
private final class ExclusionContextTable: NSTableView {
    var contextMenuForRow: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, let menu = contextMenuForRow?(index) else { return nil }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return menu
    }
}

@MainActor
private final class ExclusionAlbumGridLayout: NSCollectionViewLayout {
    private let cover: CGFloat = 156
    private let itemHeight: CGFloat = 198
    private let gap: CGFloat = 16

    private func headerHeight(_ section: Int) -> CGFloat {
        collectionView?.numberOfItems(inSection: section) == 0 ? 52 : 30
    }

    private func sectionHeight(_ section: Int) -> CGFloat {
        let count = collectionView?.numberOfItems(inSection: section) ?? 0
        let rows = (count + 1) / 2
        return headerHeight(section) + (rows > 0 ? CGFloat(rows) * itemHeight + CGFloat(rows - 1) * gap : 0)
    }

    private func sectionOrigin(_ section: Int) -> CGFloat {
        (0..<section).reduce(CGFloat(0)) { $0 + sectionHeight($1) + 20 }
    }

    var resultsHeight: CGFloat {
        guard let collectionView else { return 0 }
        let sections = collectionView.numberOfSections
        return sections > 0 ? sectionOrigin(sections - 1) + sectionHeight(sections - 1) + 12 : 0
    }

    override var collectionViewContentSize: NSSize {
        guard let collectionView else { return .zero }
        let viewportHeight = collectionView.enclosingScrollView?.contentView.bounds.height ?? 0
        return NSSize(width: collectionView.bounds.width, height: max(viewportHeight, resultsHeight))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let collectionView, collectionView.numberOfSections > 0 else { return [] }
        var attributes: [NSCollectionViewLayoutAttributes] = []
        for section in 0..<collectionView.numberOfSections {
            if let header = layoutAttributesForSupplementaryView(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                 at: IndexPath(item: 0, section: section)),
               header.frame.intersects(rect) { attributes.append(header) }
            for item in 0..<collectionView.numberOfItems(inSection: section) {
                if let cell = layoutAttributesForItem(at: IndexPath(item: item, section: section)),
                   cell.frame.intersects(rect) { attributes.append(cell) }
            }
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = NSRect(x: 6 + CGFloat(indexPath.item % 2) * (cover + gap),
                                  y: sectionOrigin(indexPath.section) + headerHeight(indexPath.section)
                                    + CGFloat(indexPath.item / 2) * (itemHeight + gap),
                                  width: cover, height: itemHeight)
        return attributes
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: NSCollectionView.SupplementaryElementKind,
                                                       at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard elementKind == NSCollectionView.elementKindSectionHeader, let collectionView else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        attributes.frame = NSRect(x: 6, y: sectionOrigin(indexPath.section),
                                  width: max(0, collectionView.bounds.width - 12),
                                  height: headerHeight(indexPath.section))
        return attributes
    }
}

@MainActor
private final class ExclusionCollectionView: NSCollectionView {
    var contextMenuForItem: ((IndexPath) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        selectionIndexPaths = [index]
        return contextMenuForItem?(index)
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if changed { collectionViewLayout?.invalidateLayout() }
    }
}
