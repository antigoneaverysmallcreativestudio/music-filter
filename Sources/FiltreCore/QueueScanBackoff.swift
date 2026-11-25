import Foundation

/// A bounded delay after a queue scan failed before sending any removal.
/// The caller keeps uncertain actions and the removal budget separate.
public struct QueueScanBackoff: Sendable {
    private static let delays: [TimeInterval] = [2, 4, 8, 16, 30]
    private var failureStep = 0
    public private(set) var nextAttemptAt: TimeInterval?

    public init() {}

    public func allowsAttempt(at now: TimeInterval) -> Bool {
        nextAttemptAt.map { now >= $0 } ?? true
    }

    /// `now` is monotonic time at completion, so a slow scan does not consume
    /// the delay intended to give Music time to settle before the next scan.
    @discardableResult
    public mutating func recordPreActionFailure(at now: TimeInterval) -> TimeInterval {
        let delay = Self.delays[failureStep]
        failureStep = min(failureStep + 1, Self.delays.count - 1)
        nextAttemptAt = now + delay
        return delay
    }

    public mutating func reset() {
        failureStep = 0
        nextAttemptAt = nil
    }
}
