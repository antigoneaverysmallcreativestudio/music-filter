import Foundation

/// Metadata from one verified queue row. No artist is inferred from a flat
/// accessibility sentence or from the currently playing track.
public struct QueueTrackMetadata: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String

    /// Use only for fields whose individual roles have already been identified.
    /// An absent album is safe for artist/song rules, but cannot match an album.
    public init?(title: String, artist: String, album: String) {
        guard let title = Self.cleanField(title, required: true),
              let artist = Self.cleanField(artist, required: true),
              let album = Self.cleanField(album, required: false) else { return nil }
        self.title = title
        self.artist = artist
        self.album = album
    }

    /// Accept only this structural form: title newline artist — album.
    /// Extra or flattened lines and ambiguous credit delimiters are rejected.
    public init?(accessibilityValue: String) {
        guard accessibilityValue.utf8.count <= 16_384 else { return nil }
        let text = queueCanonicalText(accessibilityValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Self.parse(lines: text.components(separatedBy: .newlines)) else { return nil }
        self = parsed
    }

    public static func parse(lines: [String]) -> QueueTrackMetadata? {
        guard lines.count == 2,
              !lines[0].contains(where: \.isNewline),
              !lines[1].contains(where: \.isNewline) else { return nil }
        let credit = lines[1].components(separatedBy: "—")
        guard credit.count == 2,
              credit[0].last?.isWhitespace == true,
              credit[1].first?.isWhitespace == true,
              !normalizedMusicText(credit[1]).isEmpty else { return nil }
        return QueueTrackMetadata(title: lines[0], artist: credit[0], album: credit[1])
    }

    public var trackSnapshot: TrackSnapshot {
        let key = queueLengthPrefixed([normalizedMusicText(title), normalizedMusicText(artist), normalizedMusicText(album)])
        return TrackSnapshot(id: "queue:" + key, title: title, artist: artist, albumArtist: "", album: album, isPlaying: false)
    }

    /// Queue accessibility does not provide a reliable albumArtist field.
    /// Use the exact credited artist as a conservative album fallback; do not
    /// preemptively remove compilation albums on a generic artist credit.
    public func matchingRule(in rules: [BanRule]) -> BanRule? {
        let snapshot = trackSnapshot
        return rules.first { rule in
            if rule.kind == .album {
                guard !album.isEmpty, let ruleArtist = rule.artist,
                      !Self.compilationCredits.contains(normalizedMusicText(ruleArtist)),
                      !Self.compilationCredits.contains(normalizedMusicText(artist)),
                      normalizedMusicText(ruleArtist) == normalizedMusicText(artist) else { return false }
            }
            return rule.matches(snapshot)
        }
    }

    private static let compilationCredits: Set<String> = [
        "various artists", "various", "multi-interprètes", "multi-interpretes",
        "artistes divers", "artistes variés"
    ]

    private static func cleanField(_ value: String, required: Bool) -> String? {
        guard value.utf8.count <= 8_192,
              !value.contains(where: \.isNewline),
              !value.contains("\u{0}"), !value.contains("\u{FFFC}") else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return required && normalizedMusicText(result).isEmpty ? nil : result
    }
}

public enum QueueSectionParser {
    public enum FutureSection: String, Equatable, Sendable {
        case autoplay
        case continuation
    }

    /// The caller must first establish that this is a section-header element,
    /// not an ordinary track. A description is accepted only on following lines.
    public static func futureSection(_ accessibilityValue: String) -> FutureSection? {
        guard accessibilityValue.utf8.count <= 4_096 else { return nil }
        var value = queueCanonicalText(accessibilityValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An accessibility attachment marker may precede the header's icon.
        while value.first == "\u{FFFC}" {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let firstLine = value.components(separatedBy: .newlines).first else { return nil }
        switch normalizedMusicText(firstLine) {
        case "lecture automatique", "autoplay": return .autoplay
        // Verified Music localization labels; the pane title "Up Next" is not
        // itself a future section and must not broaden this list.
        case "poursuivre la lecture", "continue playing": return .continuation
        default: return nil
        }
    }

    public static func isAutoplayHeader(_ accessibilityValue: String) -> Bool {
        futureSection(accessibilityValue) == .autoplay
    }
}

/// A textual snapshot complements (but never replaces) the controller's AX
/// element identity, parent, visibility, and order checks before an action.
public struct MusicQueueSnapshot: Equatable, Sendable {
    public enum Element: Equatable, Sendable {
        /// Every verified section header must be included, even unknown ones.
        case sectionHeader(String)
        case track(String)
        case separatedTrack(QueueTrackMetadata)
        case unknown(String)
    }

    public struct Candidate: Equatable, Sendable {
        public let elementIndex: Int
        public let metadata: QueueTrackMetadata
        public let section: QueueSectionParser.FutureSection
        /// Distinguishes separate occurrences of the same kind of section.
        public let headerIndex: Int
    }

    public let elements: [Element]

    public init(elements: [Element]) { self.elements = elements }

    /// Includes the entire supplied visible sequence, even unparsed rows.
    /// Identical text cannot prove that two AX nodes are the same node.
    public var identity: String {
        queueLengthPrefixed(elements.map { element in
            switch element {
            case .sectionHeader(let value): return queueLengthPrefixed(["header", queueCanonicalText(value)])
            case .track(let value): return queueLengthPrefixed(["track", queueCanonicalText(value)])
            case .separatedTrack(let value): return queueLengthPrefixed(["fields", value.title, value.artist, value.album])
            case .unknown(let value): return queueLengthPrefixed(["unknown", queueCanonicalText(value)])
            }
        })
    }

    public var autoplayTracks: [Candidate] {
        upcomingTracks.filter { $0.section == .autoplay }
    }

    public var upcomingTracks: [Candidate] {
        var currentSection: QueueSectionParser.FutureSection?
        var currentHeaderIndex = 0
        var candidates: [Candidate] = []
        for (index, element) in elements.enumerated() {
            switch element {
            case .sectionHeader(let value):
                currentSection = QueueSectionParser.futureSection(value)
                currentHeaderIndex = index
            case .track(let value):
                if let section = currentSection, let metadata = QueueTrackMetadata(accessibilityValue: value) {
                    candidates.append(Candidate(elementIndex: index, metadata: metadata,
                                                section: section, headerIndex: currentHeaderIndex))
                }
            case .separatedTrack(let metadata):
                if let section = currentSection {
                    candidates.append(Candidate(elementIndex: index, metadata: metadata,
                                                section: section, headerIndex: currentHeaderIndex))
                }
            case .unknown:
                break
            }
        }
        return candidates
    }

    public func matchingCandidates(in rules: [BanRule]) -> [Candidate] {
        upcomingTracks.filter { $0.metadata.matchingRule(in: rules) != nil }
    }
}

private func queueCanonicalText(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

private func queueLengthPrefixed(_ values: [String]) -> String {
    values.map { "\($0.utf8.count):\($0)" }.joined()
}
