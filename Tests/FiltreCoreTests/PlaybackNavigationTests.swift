import XCTest
@testable import FiltreCore

final class PlaybackNavigationTests: XCTestCase {
    private func track(_ id: String, position: Double = 10, duration: Double = 180) -> TrackSnapshot {
        TrackSnapshot(id: id, title: id, artist: "Artist", isPlaying: true,
                      playbackPosition: position, duration: duration)
    }

    func testReturningAcrossAnExcludedSongKeepsGoingBackwards() {
        var navigation = PlaybackNavigation()
        var gate = SkipGate()
        var commands: [PlaybackDirection] = []
        // The first Previous press may merely restart C: same identity.
        for id in ["A", "B", "C", "C", "B", "A"] {
            navigation.observe(track(id))
            if gate.evaluate(trackID: id, isBlocked: id == "B", isPlaying: true) == .skip {
                commands.append(navigation.direction)
                navigation.didSkip(in: navigation.direction)
            }
        }
        XCTAssertEqual(commands, [.forward, .backward])
    }

    func testConsecutiveExclusionsCanBeCrossedInBothDirections() {
        var navigation = PlaybackNavigation()
        var gate = SkipGate()
        var commands: [PlaybackDirection] = []
        for id in ["A", "B", "C", "D", "C", "B", "A", "B", "C", "D"] {
            navigation.observe(track(id))
            if gate.evaluate(trackID: id, isBlocked: ["B", "C"].contains(id), isPlaying: true) == .skip {
                commands.append(navigation.direction)
                navigation.didSkip(in: navigation.direction)
            }
        }
        XCTAssertEqual(commands, [.forward, .forward, .backward, .backward, .forward, .forward])
    }

    func testStaleSnapshotsDoNotConsumeACommandOrRepeatTheSkip() {
        var navigation = PlaybackNavigation()
        var gate = SkipGate()
        for id in ["A", "B", "C", "B"] { navigation.observe(track(id)) }
        XCTAssertEqual(navigation.direction, .backward)
        XCTAssertEqual(gate.evaluate(trackID: "B", isBlocked: true, isPlaying: true), .skip)
        navigation.didSkip(in: .backward)
        for _ in 0..<10 {
            navigation.observe(track("B"))
            XCTAssertEqual(gate.evaluate(trackID: "B", isBlocked: true, isPlaying: true), .none)
        }
        navigation.observe(track("A"))
        XCTAssertEqual(navigation.direction, .backward)
    }

    func testNaturalRepeatAtTheEndOfASongIsForward() {
        var navigation = PlaybackNavigation()
        navigation.observe(track("A"))
        navigation.observe(track("B", position: 179))
        navigation.observe(track("A"))
        XCTAssertEqual(navigation.direction, .forward)
    }

    func testAcceptedCommandThatDidNotChangeTrackExpires() {
        var navigation = PlaybackNavigation()
        navigation.observe(track("A"), at: 0)
        navigation.observe(track("B"), at: 1)
        navigation.didSkip(in: .forward, at: 1)
        navigation.observe(track("B"), at: 2)
        navigation.observe(track("B"), at: 4)
        navigation.observe(track("A"), at: 5)
        XCTAssertEqual(navigation.direction, .backward)
    }

    func testOwnForwardSkipTakesPrecedenceOverRepeatedTitle() {
        var navigation = PlaybackNavigation()
        navigation.observe(track("A"))
        navigation.observe(track("B"))
        navigation.didSkip(in: .forward)
        navigation.observe(track("A"))
        XCTAssertEqual(navigation.direction, .forward)
    }

    func testUnknownSelectionDoesNotInheritBackwardDirection() {
        var navigation = PlaybackNavigation()
        for id in ["A", "B", "C", "B", "New selection"] { navigation.observe(track(id)) }
        XCTAssertEqual(navigation.direction, .forward)
    }

    func testUnknownResultOfOwnBackwardCommandRetainsItsDirection() {
        var navigation = PlaybackNavigation()
        navigation.observe(track("B"))
        navigation.didSkip(in: .backward)
        navigation.observe(track("Unknown earlier song"))
        XCTAssertEqual(navigation.direction, .backward)
    }

    func testMissingTrackAndNewSessionDiscardNavigationHistory() {
        var navigation = PlaybackNavigation()
        for id in ["A", "B", "C", "B"] { navigation.observe(track(id)) }
        navigation.observe(nil)
        navigation.observe(track("A"))
        XCTAssertEqual(navigation.direction, .forward)
        navigation.didSkip(in: .backward)
        navigation.reset()
        navigation.observe(track("B"))
        XCTAssertEqual(navigation.direction, .forward)
    }

    func testBoundedHistoryRetainsImmediateNeighbors() {
        var navigation = PlaybackNavigation(capacity: 4)
        for id in 0..<100 { navigation.observe(track(String(id))) }
        navigation.observe(track("98"))
        XCTAssertEqual(navigation.direction, .backward)
        navigation.observe(track("99"))
        XCTAssertEqual(navigation.direction, .forward)
        navigation.observe(track("0"))
        XCTAssertEqual(navigation.direction, .forward)
    }

    func testManualReturnToLastObservedExcludedSongRearmsItBackwards() {
        var navigation = PlaybackNavigation()
        var gate = SkipGate()
        let now = Date(timeIntervalSince1970: 100)
        let excluded = track("A")
        navigation.observe(excluded, at: 1)
        XCTAssertEqual(gate.evaluate(trackID: excluded.identity, isBlocked: true,
                                     isPlaying: true, now: now), .skip)
        navigation.didSkip(in: .forward, at: 1)

        // Music has advanced to B, but the polling loop has not observed it.
        // A successful user Previous command returns to A before the next poll.
        navigation.didNavigateManually(in: .backward, at: 1.1)
        gate.didNavigateManually()
        navigation.observe(excluded, at: 1.2)
        XCTAssertEqual(navigation.direction, .backward)
        XCTAssertEqual(gate.evaluate(trackID: excluded.identity, isBlocked: true,
                                     isPlaying: true, now: now.addingTimeInterval(0.2)), .skip)
        navigation.didSkip(in: navigation.direction, at: 1.2)
        XCTAssertEqual(gate.evaluate(trackID: excluded.identity, isBlocked: true,
                                     isPlaying: true, now: now.addingTimeInterval(0.3)), .none)
        navigation.observe(track("Earlier"), at: 1.4)
        XCTAssertEqual(navigation.direction, .backward)
    }

    func testManualForwardUpdatesDirectionEvenWithoutIdentityChange() {
        var navigation = PlaybackNavigation()
        navigation.observe(track("A"), at: 0)
        navigation.observe(track("B"), at: 1)
        navigation.observe(track("A"), at: 2)
        XCTAssertEqual(navigation.direction, .backward)
        navigation.didNavigateManually(in: .forward, at: 2.1)
        navigation.observe(track("A"), at: 2.2)
        XCTAssertEqual(navigation.direction, .forward)
    }

    func testManualDirectionAppliesToTheFirstAvailableObservation() {
        var navigation = PlaybackNavigation()
        navigation.didNavigateManually(in: .backward, at: 1)
        navigation.observe(track("A"), at: 1.1)
        XCTAssertEqual(navigation.direction, .backward)
    }

    func testManualRearmingPreservesSkipBudgetAndTrippedLatch() {
        var gate = SkipGate(maximumSkips: 2, window: 30)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true, now: now), .skip)
        gate.didNavigateManually()
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true,
                                     now: now.addingTimeInterval(1)), .skip)
        gate.didNavigateManually()
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true,
                                     now: now.addingTimeInterval(2)), .requiresPause)
        gate.didNavigateManually()
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true,
                                     now: now.addingTimeInterval(100)), .requiresPause)
    }

    func testManualRearmingStillAllowsNormalRollingWindowExpiry() {
        var gate = SkipGate(maximumSkips: 2, window: 30)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true, now: now), .skip)
        gate.didNavigateManually()
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true,
                                     now: now.addingTimeInterval(1)), .skip)
        gate.didNavigateManually()
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true,
                                     now: now.addingTimeInterval(30)), .skip)
    }
}

final class QueueRemovalAttemptGateTests: XCTestCase {
    func testCancelledOrUnconfirmedActionStaysQuarantinedAfterCooldown() {
        var gate = QueueRemovalAttemptGate()
        XCTAssertTrue(gate.allows("Target", at: 0))
        gate.begin("Target", at: 0)
        for time: Double in [0, 29, 30, 1000] {
            XCTAssertFalse(gate.allows("Target", at: time))
        }
        XCTAssertTrue(gate.allows("Different song", at: 1000))
    }

    func testConfirmedRemovalRetainsOnlyTheShortCooldown() {
        var gate = QueueRemovalAttemptGate()
        gate.begin("Target", at: 10)
        gate.confirm("Target")
        XCTAssertFalse(gate.allows("Target", at: 39))
        XCTAssertTrue(gate.allows("Target", at: 40))
    }

    func testOnlyExplicitResetAllowsUnconfirmedTargetAgain() {
        var gate = QueueRemovalAttemptGate()
        gate.begin("Target", at: 0)
        gate.reset()
        XCTAssertTrue(gate.allows("Target", at: 1))
    }

    func testQuarantineHasABoundedSafeLimit() {
        var gate = QueueRemovalAttemptGate()
        for index in 0..<128 { gate.begin(String(index), at: 0) }
        XCTAssertFalse(gate.allows("New target", at: 1000))
        gate.reset()
        XCTAssertTrue(gate.allows("New target", at: 1001))
    }
}
