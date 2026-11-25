import AppKit

/// A keyboard-capable panel that remains at the ordinary window level and
/// avoids automatic focus handoffs when interacting with the status menu.
@MainActor
final class MusicFilterPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style.union(.nonactivatingPanel),
                   backing: backingStoreType, defer: flag)
        isFloatingPanel = false
        level = .normal
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Search handles Escape itself. Keep the window open, as before, instead
    // of adopting NSPanel's default Escape-to-close behavior.
    override func cancelOperation(_ sender: Any?) {}
}

@MainActor
enum MusicFilterAbout {
    private static var window: NSWindow?
    static var existingWindow: NSWindow? { window }

    static func show() {
        if window == nil { window = makeWindow() }
        // Explicit menu commands run after tracking has finished.
        NSApp.activate()
        window?.makeKey()
        window?.orderFrontRegardless()
    }

    private static func makeWindow() -> NSWindow {
        let window = MusicFilterPanel(contentRect: NSRect(x: 0, y: 0, width: 376, height: 280),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("About Music Filter", "À propos de Music Filter")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.backgroundColor = .windowBackgroundColor
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.identifier = NSUserInterfaceItemIdentifier("musicFilter.about")

        let content = NSView()
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let icon = NSImageView()
        icon.image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityLabel(L("Music Filter icon", "Icône Music Filter"))
        stack.addArrangedSubview(icon)
        icon.widthAnchor.constraint(equalToConstant: 58).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 58).isActive = true
        stack.setCustomSpacing(20, after: icon)

        let name = label("Music Filter", size: 18, color: .labelColor, weight: .semibold)
        stack.addArrangedSubview(name)
        stack.setCustomSpacing(18, after: name)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionLabel = label("Version " + version)
        stack.addArrangedSubview(versionLabel)
        stack.setCustomSpacing(20, after: versionLabel)
        let designedBy = label(L("Designed by", "Conçu par"))
        stack.addArrangedSubview(designedBy)
        stack.setCustomSpacing(4, after: designedBy)
        stack.addArrangedSubview(label("Antigone, a very small creative studio."))

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: 320)
        ])

        // AppKit repositions its title-bar button during layout. Use its public
        // native-button factory so the requested inset remains stable instead.
        if let close = NSWindow.standardWindowButton(.closeButton, for: window.styleMask) {
            window.standardWindowButton(.closeButton)?.isHidden = true
            close.target = window
            close.action = #selector(NSWindow.performClose(_:))
            close.identifier = NSUserInterfaceItemIdentifier("musicFilter.about.close")
            let size = close.frame.size
            close.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(close, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                close.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
                close.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
                close.widthAnchor.constraint(equalToConstant: size.width),
                close.heightAnchor.constraint(equalToConstant: size.height)
            ])
        }
        window.center()
        return window
    }

    private static func label(_ text: String, size: CGFloat = 12,
                              color: NSColor = .secondaryLabelColor,
                              weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
}

