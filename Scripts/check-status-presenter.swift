// Isolated presenter lifecycle checks; no visible status item or Music commands.
// Compile with Sources/FiltreCore/*.swift and Sources/FiltreMusique/MainViewController.swift.
// Requires Xcode 27; native-session checks run on macOS 27 or later.
import AppKit

@MainActor
private final class StubMenu: NSMenu {
    var visits = 0
    var body: (() -> Void)?
    var result = true
    var cancellations = 0
    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        visits += 1
        body?()
        return result
    }
    override func cancelTracking() { cancellations += 1 }
}

@main
@MainActor
private struct Checks {
    static var count = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        count += 1
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        window.contentView!.addSubview(button)
        let cell = button.cell as! NSButtonCell
        let initialMask: NSCell.StyleMask = [.changeGrayCellMask, .contentsCellMask]
        cell.showsStateBy = initialMask
        button.state = .off
        let primary = StubMenu()
        let secondary = StubMenu()
        var presenter: StatusMenuPresenter!
        var openings = 0
        var actions = 0
        presenter = StatusMenuPresenter(button: button, primaryMenu: primary, recentMenu: secondary, onWillPresent: {
            openings += 1
            expect(button.state == .on, "Opening callback must see the persistent selected state")
            expect(cell.showsStateBy == .changeBackgroundCellMask, "Opening must retain native background state rendering")
        })
        primary.body = {
            expect(button.state == .on, "Primary popup must hold the selected state")
            button.highlight(false)
            expect(button.state == .on, "Transient AppKit unhighlight must not clear persistent state")
            expect(!presenter.presentPrimaryMenu(), "Nested presentation must be rejected")
            presenter.performAfterTracking {
                expect(button.state == .off, "Deferred action must run after state restoration")
                expect(cell.showsStateBy == initialMask, "Deferred action must run after mask restoration")
                actions += 1
            }
            expect(actions == primary.visits - 1, "Explicit window action ran while menu was tracking")
        }
        for _ in 0..<3 {
            expect(presenter.presentPrimaryMenu(), "Primary presentation return value lost")
            expect(button.state == .off && cell.showsStateBy == initialMask, "State not restored after primary close")
            expect(!button.isHighlighted, "Pressed highlight remained after primary close")
        }
        expect(actions == 3 && primary.visits == 3, "Repeated lifecycle count mismatch")
        secondary.body = {
            expect(button.state == .on, "Secondary popup must also hold selected state")
            button.highlight(false)
            expect(button.state == .on, "Secondary state lost after pointer leaves button")
        }
        for (type, flags) in [(NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()), (.leftMouseDown, .control)] {
            let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            expect(presenter.presentMenu(for: event), "Secondary click route failed")
            expect(button.state == .off && cell.showsStateBy == initialMask, "Secondary state not restored")
        }
        expect(secondary.visits == 2 && openings == 5, "Primary/secondary routing mismatch")
        presenter.performAfterTracking { actions += 1 }
        expect(actions == 4, "Idle action should run immediately")
        presenter.invalidate()
        expect(!presenter.presentPrimaryMenu(), "Invalidated presenter reopened")

        // An opening callback may invalidate the presenter before popUp.
        let cancelledPrimary = StubMenu()
        var cancelled: StatusMenuPresenter!
        cancelled = StatusMenuPresenter(button: button, primaryMenu: cancelledPrimary, recentMenu: StubMenu(), onWillPresent: {
            cancelled.performAfterTracking { actions += 100 }
            cancelled.invalidate()
        })
        expect(!cancelled.presentPrimaryMenu(), "Invalidation during opening should cancel presentation")
        expect(cancelledPrimary.visits == 0 && cancelledPrimary.cancellations == 1, "Cancelled opening reached popup")
        expect(button.state == .off && cell.showsStateBy == initialMask, "Early return leaked selected state")
        expect(actions == 4, "Invalidated presenter ran deferred actions")

        // Restoration must preserve non-default state, not force everything off.
        button.allowsMixedState = true
        button.state = .mixed
        let dismissedMenu = StubMenu()
        dismissedMenu.result = false
        let dismissed = StatusMenuPresenter(button: button, primaryMenu: dismissedMenu, recentMenu: StubMenu())
        expect(!dismissed.presentPrimaryMenu(), "Cancelled popup return value lost")
        expect(button.state == .mixed && cell.showsStateBy == initialMask, "Prior mixed state not restored")
        dismissed.invalidate()
        expect(!window.isVisible, "Checks must never show a window")
        print("PASS: \(count) presenter lifecycle checks; hidden window only, no status item, no UI tracking, no Music calls.")
    }
}
