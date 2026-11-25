import Foundation

/// An action with an uncertain outcome must not be retried just because its
/// callback belonged to an old playback state. Cancellation is not confirmation.
public struct QueueRemovalAttemptGate: Sendable {
    private var attempts: [String: TimeInterval] = [:]
    private var unconfirmed: Set<String> = []
    public init() {}

    public func allows(_ identity: String, at now: TimeInterval) -> Bool {
        guard !unconfirmed.contains(identity), unconfirmed.count < 128 else { return false }
        return attempts[identity].map { now - $0 >= 30 } ?? true
    }

    public mutating func begin(_ identity: String, at now: TimeInterval) {
        attempts = attempts.filter { now - $0.value < 30 }
        attempts[identity] = now
        unconfirmed.insert(identity)
    }

    public mutating func confirm(_ identity: String) { unconfirmed.remove(identity) }

    /// Explicit option reset or a different Music process, never a track change.
    public mutating func reset() { attempts = [:]; unconfirmed = [] }
}

/// Checks an ordered metadata transition without relying on reusable AX row IDs.
/// The caller must independently verify the same process, section and viewport.
public enum QueueRemovalConfirmation {
    public enum Result: Equatable, Sendable {
        case confirmed(appendedCount: Int)
        /// The UI may not have applied the action yet. Only re-read; do not send
        /// another removal command while confirmation is pending.
        case unchanged
        case unverifiable(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case incompleteSnapshot
        case invalidTargetIndex
        case duplicateTarget
        case targetStillPresent
        case sequenceChanged
        case ambiguousTailReplacement
    }

    /// Each complete snapshot is a contiguous, fully parsed visible prefix of
    /// a future queue section starting at its verified header. Never omit an unparsed row.
    /// The after snapshot must retain every known survivor in the same order.
    public static func evaluate(before: [QueueTrackMetadata], targetIndex: Int,
                                after: [QueueTrackMetadata],
                                beforeComplete: Bool, afterComplete: Bool) -> Result {
        guard beforeComplete, afterComplete else { return .unverifiable(.incompleteSnapshot) }
        guard before.indices.contains(targetIndex) else { return .unverifiable(.invalidTargetIndex) }

        // Synthetic queue IDs contain only canonical, case/whitespace-normalized
        // title + artist + album. They preserve diacritics and full credits;
        // exclusion rules and collaboration matching are never used here.
        let beforeKeys = before.map { $0.trackSnapshot.id }
        let afterKeys = after.map { $0.trackSnapshot.id }
        let target = beforeKeys[targetIndex]
        guard beforeKeys.filter({ $0 == target }).count == 1,
              afterKeys.filter({ $0 == target }).count <= 1 else {
            return .unverifiable(.duplicateTarget)
        }
        if beforeKeys == afterKeys { return .unchanged }
        guard !afterKeys.contains(target) else { return .unverifiable(.targetStillPresent) }

        var survivors = beforeKeys
        survivors.remove(at: targetIndex)
        guard afterKeys.count >= survivors.count,
              afterKeys.starts(with: survivors) else { return .unverifiable(.sequenceChanged) }
        let appendedCount = afterKeys.count - survivors.count
        // When the target was last, replacing it and removing it then appending
        // another item produce the same metadata. Require a retained successor
        // before allowing a suffix of new items to count as a confirmed removal.
        guard appendedCount == 0 || targetIndex < beforeKeys.count - 1 else {
            return .unverifiable(.ambiguousTailReplacement)
        }
        return .confirmed(appendedCount: appendedCount)
    }
}
