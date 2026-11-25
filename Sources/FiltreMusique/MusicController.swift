import AppKit

enum MusicControlError: LocalizedError {
    case automationDenied
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return L("Allow Music Filter to control Music in System Settings → Privacy & Security → Automation.", "Autorisez Music Filter à contrôler Musique dans Réglages Système → Confidentialité et sécurité → Automatisation.")
        case .unavailable(let message): return message
        }
    }
}

/// All Apple events run serially off the UI thread. A second read inside the
/// command prevents a delayed skip from advancing an unrelated new track.
final class MusicController {
    private let queue = DispatchQueue(label: "dev.julienmerault.FiltreMusique.music")
    private let operationLock = NSLock()
    private var operationGeneration: UInt64 = 0

    private struct OperationContext {
        let generation: UInt64
        let processID: pid_t?
    }

    /// Cancels queued work immediately, without waiting for the Apple-event
    /// queue. An Apple event already sent to Music cannot be recalled; its
    /// eventual result is discarded if this generation has been invalidated.
    func invalidatePendingOperations() {
        operationLock.lock()
        operationGeneration &+= 1
        operationLock.unlock()
    }

    private func operation(expectedProcessID: pid_t?) -> OperationContext {
        operationLock.lock()
        let generation = operationGeneration
        operationLock.unlock()
        // Even callers that omit a PID are pinned to the process alive now.
        // Merely constructing a request must never launch Music.
        let processID = expectedProcessID
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                .first(where: { !$0.isTerminated })?.processIdentifier
        return OperationContext(generation: generation, processID: processID)
    }

    private func canPerform(_ operation: OperationContext) -> Bool {
        guard let processID = operation.processID,
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                .contains(where: { !$0.isTerminated && $0.processIdentifier == processID }) else { return false }
        operationLock.lock()
        defer { operationLock.unlock() }
        return operation.generation == operationGeneration
    }

    private func deliver<Value>(_ result: Result<Value, Error>, for operation: OperationContext,
                                cancelledValue: Value, completion: @escaping (Result<Value, Error>) -> Void) {
        DispatchQueue.main.async {
            // Closure or relaunch may happen after the queued operation finishes
            // but before its callback reaches the app's main actor.
            completion(self.canPerform(operation) ? result : .success(cancelledValue))
        }
    }

    private static let helpers = """
    on describeTrack()
        tell application id "com.apple.Music"
            set theTrack to current track
            set trackTitle to name of theTrack as text
            set trackArtist to artist of theTrack as text
            set trackID to ""
            set albumArtist to ""
            set trackAlbum to ""
            try
                set trackID to persistent ID of theTrack as text
            end try
            try
                set albumArtist to album artist of theTrack as text
            end try
            try
                set trackAlbum to album of theTrack as text
            end try
            return {trackID, trackTitle, trackArtist, albumArtist, trackAlbum}
        end tell
    end describeTrack
    """

    func read(expectedProcessID: pid_t? = nil, completion: @escaping (Result<TrackSnapshot?, Error>) -> Void) {
        let operation = operation(expectedProcessID: expectedProcessID)
        queue.async {
            guard self.canPerform(operation) else {
                self.deliver(.success(nil), for: operation, cancelledValue: nil, completion: completion)
                return
            }
            let result: Result<TrackSnapshot?, Error> = Result {
                guard let descriptor = try self.execute(Self.helpers + """

                with timeout of 4 seconds
                    if application id "com.apple.Music" is not running then return {}
                    tell application id "com.apple.Music"
                        set isPlaying to player state is playing
                        set playbackPosition to -1
                        set trackDuration to -1
                        try
                            set playbackPosition to player position
                            set trackDuration to duration of current track
                        end try
                    end tell
                    try
                        set details to my describeTrack()
                    on error messageText number errorCode
                        if errorCode is -1728 then return {}
                        error messageText number errorCode
                    end try
                    return details & {isPlaying, playbackPosition, trackDuration}
                end timeout
                """, operation: operation) else { return nil }
                guard descriptor.numberOfItems >= 6 else { return nil }
                let title = descriptor.atIndex(2)?.stringValue ?? ""
                let artist = descriptor.atIndex(3)?.stringValue ?? ""
                guard !title.isEmpty, !artist.isEmpty else {
                    throw MusicControlError.unavailable(L("Music is not sharing this song’s title and artist. Waiting for the next song.", "Musique ne transmet pas le titre et l’artiste de ce morceau. Le filtre attend le suivant."))
                }
                let position = descriptor.atIndex(7)?.doubleValue ?? -1
                let duration = descriptor.atIndex(8)?.doubleValue ?? -1
                return TrackSnapshot(id: descriptor.atIndex(1)?.stringValue ?? "", title: title,
                    artist: artist, albumArtist: descriptor.atIndex(4)?.stringValue ?? "",
                    album: descriptor.atIndex(5)?.stringValue ?? "",
                    isPlaying: descriptor.atIndex(6)?.booleanValue ?? false,
                    playbackPosition: position >= 0 && position.isFinite ? position : nil,
                    duration: duration > 0 && duration.isFinite ? duration : nil)
            }
            self.deliver(result, for: operation, cancelledValue: nil, completion: completion)
        }
    }

    func skip(_ expected: TrackSnapshot, direction: PlaybackDirection = .forward,
              pauseInstead: Bool = false, expectedProcessID: pid_t? = nil,
              completion: @escaping (Result<Bool, Error>) -> Void) {
        let operation = operation(expectedProcessID: expectedProcessID)
        queue.async {
            guard self.canPerform(operation) else {
                self.deliver(.success(false), for: operation, cancelledValue: false, completion: completion)
                return
            }
            let result: Result<Bool, Error> = Result {
                let args = [expected.id, expected.title, expected.artist, expected.albumArtist, expected.album]
                    .map(Self.literal).joined(separator: ", ")
                guard let descriptor = try self.execute(Self.helpers + """

                with timeout of 4 seconds
                    if application id "com.apple.Music" is not running then return false
                    tell application id "com.apple.Music"
                        if player state is not playing then return false
                    end tell
                    set expected to {\(args)}
                    set actual to my describeTrack()
                    if item 2 of actual is not item 2 of expected then return false
                    if item 3 of actual is not item 3 of expected then return false
                    if item 1 of expected is not "" and item 1 of actual is not item 1 of expected then return false
                    if item 4 of expected is not "" and item 4 of actual is not item 4 of expected then return false
                    if item 5 of expected is not "" and item 5 of actual is not item 5 of expected then return false
                    tell application id "com.apple.Music" to \(pauseInstead ? "pause" : (direction == .backward ? "previous track" : "next track"))
                    return true
                end timeout
                """, operation: operation) else { return false }
                return descriptor.booleanValue
            }
            self.deliver(result, for: operation, cancelledValue: false, completion: completion)
        }
    }

    private static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func execute(_ source: String, operation: OperationContext) throws -> NSAppleEventDescriptor? {
        guard canPerform(operation) else { return nil }
        guard let script = NSAppleScript(source: source) else {
            throw MusicControlError.unavailable(L("Could not prepare the connection to Music.", "La connexion à Musique n’a pas pu être préparée."))
        }
        var error: NSDictionary?
        // Recheck at the last cancellable point, immediately before sending
        // Apple events. Do not hold the lock while Music is handling a command.
        guard canPerform(operation) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 { throw MusicControlError.automationDenied }
            throw MusicControlError.unavailable(L("Music isn’t responding right now (\(code)). Try playing a song.", "Musique ne répond pas pour le moment (\(code)). Réessayez après avoir lancé un morceau."))
        }
        return result
    }
}
