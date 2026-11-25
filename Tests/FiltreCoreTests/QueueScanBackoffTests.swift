import XCTest
@testable import FiltreCore

final class QueueScanBackoffTests: XCTestCase {
    func testNewPolicyAllowsTheFirstScanImmediately() {
        let policy = QueueScanBackoff()
        XCTAssertNil(policy.nextAttemptAt)
        XCTAssertTrue(policy.allowsAttempt(at: 0))
    }

    func testFailuresUseBoundedProgressiveDelaysWithoutPermanentPause() {
        var policy = QueueScanBackoff()
        var completionTime = 100.0
        for expectedDelay in [2.0, 4, 8, 16, 30, 30, 30, 30] {
            XCTAssertEqual(policy.recordPreActionFailure(at: completionTime), expectedDelay)
            let deadline = completionTime + expectedDelay
            XCTAssertEqual(policy.nextAttemptAt, deadline)
            XCTAssertFalse(policy.allowsAttempt(at: deadline - 0.001))
            XCTAssertTrue(policy.allowsAttempt(at: deadline))
            XCTAssertTrue(policy.allowsAttempt(at: deadline + 100))
            completionTime = deadline + 1
        }
    }

    func testDelayStartsAtCompletionRatherThanAtScanStart() {
        var policy = QueueScanBackoff()
        // A scan started at 10 and took four seconds to finish.
        policy.recordPreActionFailure(at: 14)
        XCTAssertFalse(policy.allowsAttempt(at: 14))
        XCTAssertFalse(policy.allowsAttempt(at: 15.999))
        XCTAssertTrue(policy.allowsAttempt(at: 16))
    }

    func testSuccessfulRecoveryClearsTheDeadlineAndRestartsTheSequence() {
        var policy = QueueScanBackoff()
        policy.recordPreActionFailure(at: 10)
        policy.recordPreActionFailure(at: 13)
        policy.recordPreActionFailure(at: 18)
        policy.reset()
        XCTAssertNil(policy.nextAttemptAt)
        XCTAssertTrue(policy.allowsAttempt(at: 18))
        XCTAssertEqual(policy.recordPreActionFailure(at: 20), 2)
    }

    func testPollingTheDeadlineDoesNotExtendItOrEscalateTheDelay() {
        var policy = QueueScanBackoff()
        policy.recordPreActionFailure(at: 100)
        for tick in 0..<200 {
            _ = policy.allowsAttempt(at: 100 + Double(tick) / 100)
        }
        XCTAssertEqual(policy.nextAttemptAt, 102)
        XCTAssertTrue(policy.allowsAttempt(at: 102))
        XCTAssertEqual(policy.recordPreActionFailure(at: 103), 4)
    }
}
