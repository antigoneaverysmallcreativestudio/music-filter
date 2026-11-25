import XCTest
@testable import FiltreCore

final class MusicSessionStateTests: XCTestCase {
    func testInitialStateIsDormantAndDuplicateAbsenceChangesNothing() {
        var state = MusicSessionState()
        XCTAssertNil(state.processID)
        XCTAssertEqual(state.generation, 0)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.beginRequest())
        XCTAssertFalse(state.reconcile(processID: nil))
        XCTAssertFalse(state.stop())
        XCTAssertEqual(state.generation, 0)
    }

    func testInventoryReconciliationRecoversMissedLaunchAfterDormantPeriod() throws {
        var state = MusicSessionState()
        state.reconcile(processID: 101)
        let oldRead = try XCTUnwrap(state.beginRequest())
        state.reconcile(processID: nil)
        for _ in 0..<4 {
            XCTAssertFalse(state.reconcile(processID: nil))
            XCTAssertNil(state.beginRequest(), "Closed Music must not receive a read request")
        }

        // No launch notification arrived. A menu opening or watchdog observes
        // the live inventory and starts the new session without a user toggle.
        XCTAssertTrue(state.reconcile(processID: 28_363))
        let recoveredRead = try XCTUnwrap(state.beginRequest())
        XCTAssertEqual(recoveredRead.processID, 28_363)
        XCTAssertFalse(state.finishRequest(oldRead))
        XCTAssertTrue(state.accepts(recoveredRead))

        // A later duplicate launch notification must not cancel that read.
        let recoveredGeneration = state.generation
        XCTAssertFalse(state.reconcile(processID: 28_363))
        XCTAssertEqual(state.generation, recoveredGeneration)
        XCTAssertTrue(state.finishRequest(recoveredRead))
    }

    func testActiveSessionAcceptsOnlyOneRequestAtATime() throws {
        var state = MusicSessionState()
        XCTAssertTrue(state.reconcile(processID: 101))
        XCTAssertEqual(state.processID, 101)
        XCTAssertEqual(state.generation, 1)
        let first = try XCTUnwrap(state.beginRequest())
        XCTAssertEqual(first.processID, 101)
        XCTAssertEqual(first.generation, state.generation)
        XCTAssertTrue(state.accepts(first))
        XCTAssertTrue(state.isBusy)
        XCTAssertNil(state.beginRequest())
        XCTAssertTrue(state.finishRequest(first))
        XCTAssertFalse(state.isBusy)
        XCTAssertFalse(state.accepts(first))
        XCTAssertFalse(state.finishRequest(first))
        let second = try XCTUnwrap(state.beginRequest())
        XCTAssertGreaterThan(second.requestID, first.requestID)
        XCTAssertEqual(second.generation, first.generation)
    }

    func testStoppingDuringReadInvalidatesItsCompletion() throws {
        var state = MusicSessionState()
        state.reconcile(processID: 101)
        let read = try XCTUnwrap(state.beginRequest())
        XCTAssertTrue(state.stop())
        XCTAssertNil(state.processID)
        XCTAssertGreaterThan(state.generation, read.generation)
        XCTAssertFalse(state.accepts(read))
        XCTAssertFalse(state.finishRequest(read))
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.beginRequest())
    }

    func testStoppingDuringSkipInvalidatesItsCompletion() throws {
        var state = MusicSessionState()
        state.reconcile(processID: 101)
        let read = try XCTUnwrap(state.beginRequest())
        XCTAssertTrue(state.finishRequest(read))
        let skip = try XCTUnwrap(state.beginRequest())
        state.reconcile(processID: nil)
        XCTAssertFalse(state.accepts(skip))
        XCTAssertFalse(state.finishRequest(skip))
        XCTAssertFalse(state.isBusy)
    }

    func testRapidProcessReplacementRejectsOldCallbackWithoutConsumingNewRead() throws {
        var state = MusicSessionState()
        state.reconcile(processID: 101)
        let oldRead = try XCTUnwrap(state.beginRequest())
        XCTAssertTrue(state.reconcile(processID: 202))
        let newRead = try XCTUnwrap(state.beginRequest())
        XCTAssertGreaterThan(newRead.generation, oldRead.generation)
        XCTAssertFalse(state.accepts(oldRead))
        XCTAssertFalse(state.finishRequest(oldRead))
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.accepts(newRead))
        XCTAssertNil(state.beginRequest())
        XCTAssertTrue(state.finishRequest(newRead))
    }

    func testLateSkipFailureCannotConsumeNewSessionRequest() throws {
        var state = MusicSessionState()
        state.reconcile(processID: 101)
        let read = try XCTUnwrap(state.beginRequest())
        state.finishRequest(read)
        let oldSkip = try XCTUnwrap(state.beginRequest())
        state.stop()
        state.reconcile(processID: 202)
        let newRead = try XCTUnwrap(state.beginRequest())
        XCTAssertFalse(state.finishRequest(oldSkip))
        XCTAssertTrue(state.accepts(newRead))
        XCTAssertTrue(state.isBusy)
    }

    func testProcessIDReuseAfterObservedStopStillCreatesNewGeneration() throws {
        var state = MusicSessionState()
        state.reconcile(processID: 101)
        let oldRead = try XCTUnwrap(state.beginRequest())
        state.stop()
        state.reconcile(processID: 101)
        let newRead = try XCTUnwrap(state.beginRequest())
        XCTAssertEqual(newRead.processID, oldRead.processID)
        XCTAssertGreaterThan(newRead.generation, oldRead.generation)
        XCTAssertFalse(state.finishRequest(oldRead))
        XCTAssertTrue(state.accepts(newRead))
    }

    func testDuplicateLaunchObservationsPreserveInFlightWork() throws {
        var state = MusicSessionState()
        state.reconcile(processID: 101)
        let request = try XCTUnwrap(state.beginRequest())
        XCTAssertFalse(state.reconcile(processID: 101))
        XCTAssertFalse(state.reconcile(processID: 101))
        XCTAssertEqual(state.generation, request.generation)
        XCTAssertTrue(state.accepts(request))
        XCTAssertTrue(state.isBusy)
    }

    func testOldReadCallbackCannotConsumeSubsequentSkipInSameSession() throws {
        var state = MusicSessionState()
        state.reconcile(processID: 101)
        let read = try XCTUnwrap(state.beginRequest())
        state.finishRequest(read)
        let skip = try XCTUnwrap(state.beginRequest())
        XCTAssertEqual(read.generation, skip.generation)
        XCTAssertFalse(state.finishRequest(read))
        XCTAssertTrue(state.accepts(skip))
        XCTAssertTrue(state.isBusy)
    }

    func testUnrelatedTokensCannotFinishCurrentRequest() throws {
        var state = MusicSessionState()
        state.reconcile(processID: 101)
        let request = try XCTUnwrap(state.beginRequest())
        let invalid = [
            MusicSessionToken(generation: request.generation + 1, requestID: request.requestID, processID: request.processID),
            MusicSessionToken(generation: request.generation, requestID: request.requestID + 1, processID: request.processID),
            MusicSessionToken(generation: request.generation, requestID: request.requestID, processID: 202)
        ]
        for token in invalid {
            XCTAssertFalse(state.accepts(token))
            XCTAssertFalse(state.finishRequest(token))
            XCTAssertTrue(state.accepts(request))
        }
    }

    func testInvalidProcessIdentifiersAreTreatedAsAbsent() throws {
        var state = MusicSessionState()
        XCTAssertFalse(state.reconcile(processID: 0))
        XCTAssertFalse(state.reconcile(processID: -1))
        XCTAssertNil(state.beginRequest())
        state.reconcile(processID: 101)
        let request = try XCTUnwrap(state.beginRequest())
        XCTAssertTrue(state.reconcile(processID: 0))
        XCTAssertNil(state.processID)
        XCTAssertFalse(state.finishRequest(request))
    }
}
