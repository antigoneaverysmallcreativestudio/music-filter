// Isolated presenter lifecycle checks; no visible status item or Music commands.
// Compile with Sources/FiltreCore/*.swift and Sources/FiltreMusique/MainViewController.swift.
// Requires Xcode 27; native-session checks run on macOS 27 or later.
import AppKit

@available(macOS 27.0, *)
@MainActor
private final class FakeSession: NSStatusItemExpandedInterfaceSession {
    var cancellations = 0
    var onCancel: (() -> Void)?
    override func cancel() { cancellations += 1; onCancel?() }
}

@available(macOS 27.0, *)
@MainActor
private final class FakeStatusItem: NSStatusItem {
    var currentSession: FakeSession?
    private weak var sessionDelegate: NSStatusItemExpandedInterfaceDelegate?
    override var expandedInterfaceSession: NSStatusItemExpandedInterfaceSession? { currentSession }
    override var expandedInterfaceDelegate: NSStatusItemExpandedInterfaceDelegate? {
        get { sessionDelegate }
        set { sessionDelegate = newValue }
    }
    func begin(_ session: FakeSession) {
        currentSession = session
        sessionDelegate?.statusItem(self, didBegin: session)
    }
    func end() {
        currentSession = nil
        sessionDelegate?.statusItemDidEndExpandedInterfaceSession(self, animated: false)
    }
}

@MainActor
private final class FakeMenu: NSMenu {
    var visits = 0
    var cancellations = 0
    var body: (() -> Void)?
    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        visits += 1
        body?()
        return true
    }
    override func cancelTracking() { cancellations += 1 }
}

@available(macOS 27.0, *)
@MainActor
private final class Fixture {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
    let item = FakeStatusItem()
    let primary = FakeMenu()
    let secondary = FakeMenu()
    var presenter: StatusMenuPresenter!
    init() {
        window.contentView!.addSubview(button)
        presenter = StatusMenuPresenter(button: button, primaryMenu: primary, recentMenu: secondary, statusItem: item)
    }
}

@main
@MainActor
private struct Checks {
    static var count = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        count += 1
    }
    static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard #available(macOS 27.0, *) else { print("SKIP: native sessions require macOS 27"); return }
        let fixture = Fixture()
        expect(fixture.item.statusBar == nil, "Fake status item must not be registered in menu bar")
        expect(!fixture.window.isVisible, "Fixture must never show its window")
        expect(fixture.item.expandedInterfaceDelegate === fixture.presenter, "Native delegate not installed")
        expect(fixture.button.target == nil && fixture.button.action == nil, "Native branch must let AppKit own the click")
        var actions = 0
        fixture.primary.body = {
            expect(fixture.button.state == .on, "Popup state should be held")
            fixture.presenter.performAfterTracking { actions += 1 }
        }
        for visit in 1...3 {
            let session = FakeSession()
            fixture.item.begin(session)
            expect(fixture.primary.visits == visit - 1, "didBegin must return before the popup starts")
            expect(!fixture.presenter.presentPrimaryMenu(), "Manual presentation must not overlap pending native session")
            pump()
            expect(fixture.primary.visits == visit, "Scheduled native popup did not run")
            expect(session.cancellations == 1, "Session must be cancelled exactly once after popup returns")
            expect(actions == visit - 1, "Window actions must await delayed didEnd")
            expect(fixture.button.state == .off, "Button state not restored after popup")
            fixture.item.end()
            expect(actions == visit - 1, "Window action ran inside didEnd before AppKit can finish restoring focus")
            pump()
            expect(actions == visit, "Window action did not run after both popup and session ended")
        }

        // External dismissal during synchronous popup must only cancel that popup.
        let externalSession = FakeSession()
        fixture.primary.body = {
            fixture.presenter.performAfterTracking { actions += 1 }
            fixture.item.end()
            expect(fixture.primary.cancellations == 1, "External didEnd must cancel its owned popup")
            expect(actions == 3, "Window action must still await popUp return")
        }
        fixture.item.begin(externalSession)
        pump()
        expect(actions == 4 && externalSession.cancellations == 0, "Already-ended session must not be cancelled again")

        let synchronous = FakeSession()
        fixture.primary.body = { fixture.presenter.performAfterTracking { actions += 1 } }
        synchronous.onCancel = {
            fixture.item.end()
            expect(actions == 4, "Synchronous didEnd must not activate a window inside cancellation")
        }
        fixture.item.begin(synchronous)
        pump()
        expect(actions == 5 && synchronous.cancellations == 1, "Synchronous cancellation did not flush once after returning")

        // A delayed or unrelated didEnd must not cancel the independent recent menu.
        fixture.secondary.body = {
            fixture.presenter.statusItemDidEndExpandedInterfaceSession(fixture.item, animated: false)
            expect(fixture.secondary.cancellations == 0, "Unowned native callback cancelled manual recent menu")
        }
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        expect(fixture.presenter.presentMenu(for: rightClick), "Manual recent menu failed after native session")
        expect(fixture.secondary.visits == 1, "Recent route not preserved")

        // Invalidation before the scheduled callback must leave no popup or action.
        let pending = Fixture()
        let pendingSession = FakeSession()
        pending.item.begin(pendingSession)
        pending.presenter.performAfterTracking { actions += 100 }
        pending.presenter.invalidate()
        pump()
        expect(pending.primary.visits == 0, "Invalidated pending callback opened popup")
        expect(pendingSession.cancellations == 1, "Invalidation must cancel owned session")
        expect(pending.item.expandedInterfaceDelegate == nil, "Invalidation left delegate installed")
        pending.item.end()
        expect(actions == 5, "Invalidated callback ran deferred action")

        // A callback delivered while a newer session remains active is unrelated.
        let later = FakeSession()
        fixture.primary.body = {
            fixture.presenter.statusItemDidEndExpandedInterfaceSession(fixture.item, animated: false)
            expect(fixture.primary.cancellations == 1, "Stale didEnd cancelled current active session")
        }
        fixture.item.begin(later)
        pump()
        fixture.item.end()
        fixture.presenter.invalidate()
        expect(!fixture.window.isVisible && !pending.window.isVisible, "Checks displayed a window")
        print("PASS: \(count) native-session lifecycle checks; fake unregistered status items, hidden windows, no Music calls.")
    }
}
