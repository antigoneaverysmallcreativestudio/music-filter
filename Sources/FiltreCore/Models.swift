import Foundation

/// Only the Mac's first preferred language selects the interface language.
/// Bundle matching can otherwise choose a secondary French preference when
/// the primary language is unsupported; all non-French primaries use English.
public func L(_ english: String, _ french: String) -> String {
    interfaceLanguageCode(for: Locale.preferredLanguages) == "fr" ? french : english
}

func interfaceLanguageCode(for preferredLanguages: [String]) -> String {
    let primary = preferredLanguages.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
    return primary == "fr" ? "fr" : "en"
}

/// Selects AppKit's language before it or the main bundle resolves resources.
/// This argument-domain override exists only in this process; it never changes
/// the Mac's language order or the app's saved preferences.
public func configureInterfaceLanguage() {
    configureInterfaceLanguage(preferredLanguages: Locale.preferredLanguages, defaults: .standard)
}

func configureInterfaceLanguage(preferredLanguages: [String], defaults: UserDefaults) {
    var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["AppleLanguages"] = [interfaceLanguageCode(for: preferredLanguages)]
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
}

/// App-owned errors supply bilingual descriptions. System errors can otherwise
/// inherit an unsupported system language, so retain their diagnostic identity
/// while giving the user a message in the selected interface language.
public func interfaceErrorDescription(_ error: Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription,
       !description.isEmpty {
        return description
    }
    let systemError = error as NSError
    let reference = "\(systemError.domain), \(systemError.code)"
    return L("The operation could not be completed (\(reference)). Please try again.",
             "L’opération n’a pas pu être effectuée (\(reference)). Veuillez réessayer.")
}

/// A comparison key only: displayed text retains its original spelling.
public func normalizedMusicText(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

/// The last song actually skipped or removed from the queue automatically.
/// It remains available until another automatic exclusion replaces it. The
/// caller supplies timestamps from one monotonic clock to reject stale events.
public struct RecentAutomaticExclusion: Sendable {
    public struct Song: Equatable, Sendable {
        public let title: String
        public let artist: String
        public var displayName: String { artist.isEmpty ? title : artist + " — " + title }
    }

    private var lastSong: Song?
    private var recordedAt: TimeInterval?

    public init() {}

    /// Incomplete metadata must not erase a previous valid event.
    public mutating func record(title: String, artist: String, at now: TimeInterval) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, now.isFinite else { return }
        if let recordedAt, now < recordedAt { return }
        lastSong = Song(title: title, artist: artist.trimmingCharacters(in: .whitespacesAndNewlines))
        recordedAt = now
    }

    public func song(at now: TimeInterval) -> Song? {
        guard let recordedAt, now.isFinite, now >= recordedAt else { return nil }
        return lastSong
    }
}

public struct TrackSnapshot: Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let albumArtist: String
    public let album: String
    public let isPlaying: Bool
    /// Optional timing evidence for navigation; never part of a rule or identity.
    public let playbackPosition: TimeInterval?
    public let duration: TimeInterval?

    public init(id: String, title: String, artist: String, albumArtist: String = "", album: String = "", isPlaying: Bool,
                playbackPosition: TimeInterval? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.isPlaying = isPlaying
        self.playbackPosition = playbackPosition
        self.duration = duration
    }

    /// Album rules need an album credit as well as a title. A compilation's
    /// explicit credit (for example Various Artists) covers the whole album.
    /// Only an absent album credit falls back to this track's credited artist.
    public var albumIdentityArtist: String {
        let credit = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedMusicText(credit).isEmpty
            ? artist.trimmingCharacters(in: .whitespacesAndNewlines) : credit
    }

    public var identity: String {
        // Streaming tracks may expose the same placeholder ID. Metadata must
        // participate even when an ID is present, or a new song is missed.
        let parts = [id.trimmingCharacters(in: .whitespacesAndNewlines),
                     normalizedMusicText(artist), normalizedMusicText(title),
                     normalizedMusicText(album), normalizedMusicText(albumIdentityArtist)]
        // Length-prefixing avoids ambiguous concatenations of IDs and names.
        return parts.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public struct BanRule: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case artist, album, track }

    public let id: UUID
    public let kind: Kind
    /// The artist name, album title, or song title according to the rule kind.
    public let name: String
    /// Song artist for track rules, or the album's artist identity for albums.
    public let artist: String?
    /// Optional display metadata for a track rule, never a matching condition.
    /// Older saved rules omit this key and decode with a nil value.
    public let album: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, name: String, artist: String? = nil,
                album: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.artist = artist
        self.album = album
        self.createdAt = createdAt
    }

    public func matches(_ track: TrackSnapshot) -> Bool {
        let ruleName = normalizedMusicText(name)
        guard !ruleName.isEmpty else { return false }
        switch kind {
        case .artist:
            if ruleName == normalizedMusicText(track.artist) { return true }
            // Artist exclusions include recognized collaboration credits.
            // Song and album rules below retain their exact matching scope.
            return CollaborationCredits.contains(ruleName, in: track)
        case .track:
            guard let artist, !normalizedMusicText(artist).isEmpty else { return false }
            return ruleName == normalizedMusicText(track.title)
                && normalizedMusicText(artist) == normalizedMusicText(track.artist)
        case .album:
            guard let artist, !normalizedMusicText(artist).isEmpty,
                  !normalizedMusicText(track.album).isEmpty,
                  !track.albumIdentityArtist.isEmpty else { return false }
            return ruleName == normalizedMusicText(track.album)
                && normalizedMusicText(artist) == normalizedMusicText(track.albumIdentityArtist)
        }
    }
}

/// Recognizes explicit credit conventions without arbitrary substring matching.
/// No artist is inferred from albumArtist, prose in a title, or a general comma,
/// slash, or "and" split. A band's name containing " & " remains inherently
/// ambiguous because Music supplies names rather than participant identities.
private enum CollaborationCredits {
    private static let featureWord = #"(?:feat(?:uring)?|ft)\.?"#
    private static let parenthesizedFeature = try! NSRegularExpression(
        pattern: #"\(\s*"# + featureWord + #"\s+([^()]*)\)"#)
    private static let bracketedFeature = try! NSRegularExpression(
        pattern: #"\[\s*"# + featureWord + #"\s+([^\[\]]*)\]"#)
    private static let unbracketedFeature = try! NSRegularExpression(
        pattern: #"(?:^|\s+)"# + featureWord + #"\s+"#)

    static func contains(_ artist: String, in track: TrackSnapshot) -> Bool {
        let credit = normalizedMusicText(track.artist)
        // Check the full credit first, preserving artist names that themselves
        // contain punctuation, parentheses, or a joint-credit separator.
        if matchesJointCredit(artist, in: credit) { return true }

        let artistAnnotations = extractFeatures(from: credit)
        if artistAnnotations.features.contains(where: { matchesJointCredit(artist, in: $0) }) {
            return true
        }

        // Split only explicit feat/ft/featuring markers in the artist field.
        let remainingCredit = artistAnnotations.remainder
        let markers = unbracketedFeature.matches(
            in: remainingCredit, range: NSRange(remainingCredit.startIndex..., in: remainingCredit))
        var start = remainingCredit.startIndex
        for marker in markers {
            guard let range = Range(marker.range, in: remainingCredit) else { continue }
            if matchesJointCredit(artist, in: String(remainingCredit[start..<range.lowerBound])) {
                return true
            }
            start = range.upperBound
        }
        if matchesJointCredit(artist, in: String(remainingCredit[start...])) { return true }

        // A title is evidence only when it contains a bracketed credit such as
        // "Song (feat. MAŸ)". A plain mention in the title is not a credit.
        return extractFeatures(from: normalizedMusicText(track.title)).features.contains {
            matchesJointCredit(artist, in: $0)
        }
    }

    private static func matchesJointCredit(_ artist: String, in credit: String) -> Bool {
        let credit = normalizedMusicText(credit)
        if artist == credit { return true }
        let separator = #"\s+(?:&|\+|x|×)\s+"#
        let pattern = #"(?:^|"# + separator + #")"#
            + NSRegularExpression.escapedPattern(for: artist)
            + #"(?=$|"# + separator + #")"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: credit, range: NSRange(credit.startIndex..., in: credit)) != nil
    }

    private static func extractFeatures(from text: String) -> (features: [String], remainder: String) {
        var features: [String] = []
        var remainder = text
        for expression in [parenthesizedFeature, bracketedFeature] {
            let matches = expression.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder))
            for match in matches {
                if let range = Range(match.range(at: 1), in: remainder) {
                    features.append(String(remainder[range]))
                }
            }
            // Work backwards so earlier ranges remain valid after a removal.
            for match in matches.reversed() {
                if let range = Range(match.range, in: remainder) {
                    remainder.replaceSubrange(range, with: " ")
                }
            }
        }
        return (features, remainder)
    }
}
