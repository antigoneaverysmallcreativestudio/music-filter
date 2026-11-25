import XCTest
@testable import FiltreCore

final class QueueRemovalConfirmationTests: XCTestCase {
    private func item(_ title: String, artist: String = "Artist", album: String = "Album") -> QueueTrackMetadata {
        QueueTrackMetadata(title: title, artist: artist, album: album)!
    }

    private func evaluate(_ before: [QueueTrackMetadata], at targetIndex: Int,
                          after: [QueueTrackMetadata]) -> QueueRemovalConfirmation.Result {
        QueueRemovalConfirmation.evaluate(before: before, targetIndex: targetIndex, after: after,
                                          beforeComplete: true, afterComplete: true)
    }

    func testRemovalIsConfirmedEvenWhenTheUIReusesTheTargetRow() {
        struct SimulatedRow { let id: Int; let metadata: QueueTrackMetadata }
        let before = [SimulatedRow(id: 1, metadata: item("A")),
                      SimulatedRow(id: 2, metadata: item("Target")),
                      SimulatedRow(id: 3, metadata: item("C"))]
        let after = [SimulatedRow(id: 1, metadata: item("A")),
                     SimulatedRow(id: 2, metadata: item("C"))]
        XCTAssertTrue(after.contains { $0.id == before[1].id })
        XCTAssertEqual(evaluate(before.map(\.metadata), at: 1, after: after.map(\.metadata)),
                       .confirmed(appendedCount: 0))
    }

    func testDelayedUIUpdateRemainsUnchangedUntilTheRemovalAppears() {
        let before = [item("A"), item("Target"), item("C")]
        let observations = [before, before, [item("A"), item("C")]]
        XCTAssertEqual(observations.map { evaluate(before, at: 1, after: $0) },
                       [.unchanged, .unchanged, .confirmed(appendedCount: 0)])
    }

    func testNewSuffixIsAllowedOnlyAfterEveryKnownSurvivor() {
        let before = [item("A"), item("Target"), item("C"), item("D")]
        XCTAssertEqual(evaluate(before, at: 1, after: [item("A"), item("C"), item("D"), item("New"), item("Newer")]),
                       .confirmed(appendedCount: 2))
        XCTAssertEqual(evaluate(before, at: 1, after: [item("A"), item("New"), item("C"), item("D")]),
                       .unverifiable(.sequenceChanged))
    }

    func testFirstItemRemovalRetainsItsSuccessorAsAnAnchor() {
        XCTAssertEqual(evaluate([item("Target"), item("B"), item("C")], at: 0,
                                after: [item("B"), item("C"), item("New")]), .confirmed(appendedCount: 1))
    }

    func testLastAndOnlyItemCanBeRemovedButNotReplaced() {
        let before = [item("A"), item("Target")]
        XCTAssertEqual(evaluate(before, at: 1, after: [item("A")]), .confirmed(appendedCount: 0))
        XCTAssertEqual(evaluate(before, at: 1, after: [item("A"), item("Replacement")]),
                       .unverifiable(.ambiguousTailReplacement))
        XCTAssertEqual(evaluate([item("Target")], at: 0, after: []), .confirmed(appendedCount: 0))
        XCTAssertEqual(evaluate([item("Target")], at: 0, after: [item("Replacement")]),
                       .unverifiable(.ambiguousTailReplacement))
    }

    func testDuplicateTargetBeforeOrAfterIsAmbiguous() {
        let duplicateBefore = [item("Target"), item("B"), item("TARGET")]
        XCTAssertEqual(evaluate(duplicateBefore, at: 0, after: duplicateBefore),
                       .unverifiable(.duplicateTarget))
        XCTAssertEqual(evaluate(duplicateBefore, at: 0, after: [item("B"), item("Target")]),
                       .unverifiable(.duplicateTarget))
        let before = [item("A"), item("Target"), item("C")]
        XCTAssertEqual(evaluate(before, at: 1, after: [item("A"), item("C"), item("Target"), item("TARGET")]),
                       .unverifiable(.duplicateTarget))
        XCTAssertEqual(evaluate(before, at: 1, after: [item("A"), item("C"), item("Target")]),
                       .unverifiable(.targetStillPresent))
    }

    func testReorderingReplacementAndMultipleRemovalsAreRejected() {
        let before = [item("A"), item("Target"), item("C"), item("D")]
        for after in [[item("A"), item("D"), item("C")],
                      [item("A"), item("Replacement"), item("C"), item("D")],
                      [item("A"), item("C")],
                      [item("C"), item("D")]] {
            XCTAssertEqual(evaluate(before, at: 1, after: after), .unverifiable(.sequenceChanged))
        }
    }

    func testIncompleteSnapshotsCannotConfirmOrClaimAnUnchangedView() {
        let before = [item("A"), item("Target"), item("C")]
        for flags in [(false, true), (true, false), (false, false)] {
            for after in [before, [item("A"), item("C")]] {
                XCTAssertEqual(QueueRemovalConfirmation.evaluate(before: before, targetIndex: 1, after: after,
                                                                 beforeComplete: flags.0, afterComplete: flags.1),
                               .unverifiable(.incompleteSnapshot))
            }
        }
    }

    func testInvalidTargetIndexIsRejected() {
        XCTAssertEqual(evaluate([], at: 0, after: []), .unverifiable(.invalidTargetIndex))
        XCTAssertEqual(evaluate([item("A")], at: -1, after: []), .unverifiable(.invalidTargetIndex))
        XCTAssertEqual(evaluate([item("A")], at: 1, after: []), .unverifiable(.invalidTargetIndex))
    }

    func testCanonicalNormalizationPreservesDiacriticsAndFullCredits() {
        let before = [item("A", artist: "Maÿ"), item("Target"), item("C", artist: "Lead & Guest")]
        XCTAssertEqual(evaluate(before, at: 1, after: [item(" a ", artist: "MAY\u{308}", album: " ALBUM "),
                                                     item("C", artist: "lead & guest")]),
                       .confirmed(appendedCount: 0))
        XCTAssertEqual(evaluate(before, at: 1, after: [item("A", artist: "May"), item("C", artist: "Lead & Guest")]),
                       .unverifiable(.sequenceChanged))
        XCTAssertEqual(evaluate(before, at: 1, after: [item("A", artist: "Maÿ"), item("C", artist: "Guest")]),
                       .unverifiable(.sequenceChanged))
        XCTAssertEqual(evaluate(before, at: 1, after: [item("A", artist: "Maÿ", album: "Other"),
                                                     item("C", artist: "Lead & Guest")]),
                       .unverifiable(.sequenceChanged))
    }
}
