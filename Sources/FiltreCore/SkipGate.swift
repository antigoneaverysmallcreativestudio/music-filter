import Foundation

public enum PlaybackDirection: Equatable, Sendable { case forward, backward }

/// A short, in-memory path of tracks actually observed in this Music session.
/// Music's scripting API does not report which transport button was pressed.
/// Revisiting the immediate predecessor is therefore evidence of a return,
/// unless the preceding song was reaching its natural end. Our own commands
/// have an explicit direction and take precedence over that inference.
public struct PlaybackNavigation: Sendable {
    public private(set) var direction: PlaybackDirection = .forward
    private var path: [String] = []
    private var index = 0
    private var lastTrack: TrackSnapshot?
    private var commandDirection: PlaybackDirection?
    private var commandedAt: TimeInterval?
    private let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(2, capacity) }

    public mutating func observe(_ track: TrackSnapshot?, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let track else { reset(); return }
        if !track.isPlaying || commandedAt.map({ now - $0 > 2 }) == true {
            commandDirection = nil; commandedAt = nil
        }
        guard let previous = lastTrack else {
            path = [track.identity]; index = 0; lastTrack = track
            return
        }
        lastTrack = track
        guard track.identity != previous.identity else { return }
        let commanded = commandDirection
        commandDirection = nil; commandedAt = nil
        let wasEnding: Bool
        if let position = previous.playbackPosition, let duration = previous.duration,
           position.isFinite, duration.isFinite, duration > 0 {
            wasEnding = duration - position <= 2
        } else { wasEnding = false }
        let isPredecessor = index > 0 && path[index - 1] == track.identity
        let isSuccessor = index + 1 < path.count && path[index + 1] == track.identity
        if commanded == .backward || (commanded == nil && !wasEnding && isPredecessor) {
            direction = .backward
            if isPredecessor { index -= 1 }
            else { path.insert(track.identity, at: index) }
        } else {
            direction = .forward
            if isSuccessor { index += 1 }
            else {
                path.removeSubrange((index + 1)..<path.count)
                path.append(track.identity); index += 1
            }
        }
        // Retain neighbors around the current cursor in either direction.
        if path.count > capacity {
            if index > capacity / 2 { path.removeFirst(); index -= 1 }
            else { path.removeLast() }
        }
    }

    public mutating func didSkip(in direction: PlaybackDirection, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        commandDirection = direction; commandedAt = now
    }

    /// Call only after a successful explicit user transport command. The
    /// resulting song can have the same identity as our last observation if
    /// Music visited another song between polls, so set direction immediately
    /// instead of waiting for an observed identity change.
    public mutating func didNavigateManually(in direction: PlaybackDirection,
                                            at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.direction = direction
        didSkip(in: direction, at: now)
    }

    public mutating func reset() {
        direction = .forward; path = []; index = 0
        lastTrack = nil; commandDirection = nil; commandedAt = nil
    }
}

public enum SkipDecision: Equatable, Sendable {
    case none
    case skip
    case requiresPause
}

/// Limits commands, including when Music keeps reporting a stale track after
/// a skip. Feed every observed track into this gate, including allowed tracks.
public struct SkipGate: Sendable {
    private var lastTrackID: String?
    private var skippedCurrentTrack = false
    private var skipDates: [Date] = []
    private var tripped = false
    private let maximumSkips: Int
    private let window: TimeInterval

    public init(maximumSkips: Int = 8, window: TimeInterval = 30) {
        self.maximumSkips = max(1, maximumSkips)
        self.window = max(1, window)
    }

    public mutating func evaluate(trackID: String, isBlocked: Bool, isPlaying: Bool, now: Date = Date()) -> SkipDecision {
        guard !trackID.isEmpty else { return .none }
        if lastTrackID != trackID {
            lastTrackID = trackID
            skippedCurrentTrack = false
        }
        guard isPlaying, isBlocked else { return .none }
        guard !tripped else { return .requiresPause }
        guard !skippedCurrentTrack else { return .none }
        skipDates.removeAll { now.timeIntervalSince($0) >= window }
        guard skipDates.count < maximumSkips else {
            tripped = true
            return .requiresPause
        }
        skipDates.append(now)
        skippedCurrentTrack = true
        return .skip
    }

    /// An accepted user transport command can return to the last observed song
    /// through an intermediate song that was never polled. Allow that new
    /// occurrence to be filtered once, without clearing the safety budget or
    /// resuming filtering after the rate limit has tripped.
    public mutating func didNavigateManually() {
        lastTrackID = nil
        skippedCurrentTrack = false
    }

    /// Call for an explicit user request to resume/retry filtering. A player
    /// pause/resume alone intentionally does not retry the same reported track.
    public mutating func reset() {
        lastTrackID = nil
        skippedCurrentTrack = false
        skipDates = []
        tripped = false
    }
}
