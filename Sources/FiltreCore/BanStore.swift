import Foundation

public enum BanStoreError: LocalizedError, Equatable {
    case emptyArtist
    case incompleteTrack
    case incompleteAlbum
    case unsupportedVersion(Int)
    case invalidRule
    case invalidBackup
    case backupTooLarge
    case tooManyBackupRules

    public var errorDescription: String? {
        switch self {
        case .emptyArtist: return L("Enter an artist name.", "Saisissez le nom d’un artiste.")
        case .incompleteTrack: return L("A song title and artist are required to exclude a song.", "Le titre et l’artiste sont nécessaires pour exclure un morceau.")
        case .incompleteAlbum: return L("An album title and an identified artist are required to exclude an album.", "Le titre de l’album et un artiste identifié sont nécessaires pour exclure un album.")
        case .unsupportedVersion: return L("This exclusion list was created by a newer version of Music Filter.", "Cette liste d’exclusions provient d’une version plus récente de Music Filter.")
        case .invalidRule: return L("The exclusion list contains an invalid entry.", "La liste d’exclusions contient une entrée invalide.")
        case .invalidBackup: return L("This file is not a valid Music Filter exclusion list.", "Ce fichier n’est pas une liste d’exclusions Music Filter valide.")
        case .backupTooLarge: return L("The exclusion file must be no larger than 5 MB.", "Le fichier d’exclusions ne doit pas dépasser 5 Mo.")
        case .tooManyBackupRules: return L("An exclusion file can contain up to 10,000 entries.", "Un fichier d’exclusions peut contenir jusqu’à 10 000 entrées.")
        }
    }
}

/// Access from one serial context (the app's main actor). A failed write never
/// changes the in-memory rules, and a failed read never overwrites the file.
public final class BanStore {
    public private(set) var rules: [BanRule]
    public let fileURL: URL

    public static let maximumImportBytes = 5 * 1024 * 1024
    public static let maximumImportRules = 10_000

    public struct ImportResult: Equatable, Sendable {
        public let addedCount: Int
        public let duplicateCount: Int
    }

    private struct Document: Codable {
        let version: Int
        let rules: [BanRule]

        private enum CodingKeys: String, CodingKey { case version, rules }

        init(rules: [BanRule]) {
            version = 1
            self.rules = rules
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            // Check the version before decoding rules: a future schema may
            // represent its entries differently and must never be guessed.
            guard version == 1 else { throw BanStoreError.unsupportedVersion(version) }
            rules = try container.decode([BanRule].self, forKey: .rules)
        }
    }

    private struct RuleIdentity: Hashable {
        let kind: String
        let name: String
        let artist: String

        init(_ rule: BanRule) {
            kind = rule.kind.rawValue
            name = normalizedMusicText(rule.name)
            artist = rule.kind == .artist ? "" : normalizedMusicText(rule.artist ?? "")
        }
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            rules = []
            return
        }
        rules = try Self.decodeDocument(Data(contentsOf: fileURL)).rules
    }

    /// Exports every saved exclusion, independently of the current UI category
    /// or search. Uses the same versioned JSON as local persistence, preserving
    /// IDs, creation dates and display metadata for a later offline restore.
    public func exportedData() throws -> Data {
        guard rules.count <= Self.maximumImportRules else { throw BanStoreError.tooManyBackupRules }
        let data = try Self.encodeDocument(rules)
        guard data.count <= Self.maximumImportBytes else { throw BanStoreError.backupTooLarge }
        return data
    }

    /// Fully validates the input before merging. Existing exclusions always
    /// win; neither a duplicate nor an imported UUID can overwrite local data.
    /// A single atomic commit makes failure leave the old list unchanged.
    @discardableResult
    public func importData(_ data: Data) throws -> ImportResult {
        guard data.count <= Self.maximumImportBytes else { throw BanStoreError.backupTooLarge }
        let incoming = try Self.decodeDocument(data).rules
        guard incoming.count <= Self.maximumImportRules else { throw BanStoreError.tooManyBackupRules }
        var identities = Set(rules.map(RuleIdentity.init))
        var usedIDs = Set(rules.map(\.id))
        var merged = rules
        var addedCount = 0
        var duplicateCount = 0
        for rule in incoming {
            guard identities.insert(RuleIdentity(rule)).inserted else {
                duplicateCount += 1
                continue
            }
            var id = rule.id
            while usedIDs.contains(id) { id = UUID() }
            usedIDs.insert(id)
            let imported = id == rule.id ? rule : BanRule(id: id, kind: rule.kind, name: rule.name,
                artist: rule.artist, album: rule.album, createdAt: rule.createdAt)
            merged.append(imported)
            addedCount += 1
        }
        // Keep the resulting list exportable with the same documented bounds.
        guard merged.count <= Self.maximumImportRules else { throw BanStoreError.tooManyBackupRules }
        if addedCount > 0 {
            let encoded = try Self.encodeDocument(merged)
            guard encoded.count <= Self.maximumImportBytes else { throw BanStoreError.backupTooLarge }
            try commit(merged, encodedData: encoded)
        }
        return ImportResult(addedCount: addedCount, duplicateCount: duplicateCount)
    }

    @discardableResult
    public func addArtist(_ name: String) throws -> BanRule {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedMusicText(displayName)
        guard !key.isEmpty else { throw BanStoreError.emptyArtist }
        if let existing = rules.first(where: { $0.kind == .artist && normalizedMusicText($0.name) == key }) {
            return existing
        }
        let rule = BanRule(kind: .artist, name: displayName)
        try commit(rules + [rule])
        return rule
    }

    @discardableResult
    public func addTrack(_ track: TrackSnapshot) throws -> BanRule {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        let album: String? = normalizedMusicText(albumName).isEmpty ? nil : albumName
        guard !normalizedMusicText(title).isEmpty, !normalizedMusicText(artist).isEmpty else {
            throw BanStoreError.incompleteTrack
        }
        if let index = rules.firstIndex(where: { $0.kind == .track && $0.matches(track) }) {
            let existing = rules[index]
            // Fill a previously missing display field, keeping the original
            // identity, date, wording, and matching behavior. Another edition's
            // album must not replace metadata already chosen for this rule.
            guard normalizedMusicText(existing.album ?? "").isEmpty, let album else { return existing }
            let enriched = BanRule(id: existing.id, kind: existing.kind, name: existing.name,
                                   artist: existing.artist, album: album, createdAt: existing.createdAt)
            var proposedRules = rules
            proposedRules[index] = enriched
            try commit(proposedRules)
            return enriched
        }
        let rule = BanRule(kind: .track, name: title, artist: artist, album: album)
        try commit(rules + [rule])
        return rule
    }

    @discardableResult
    public func addAlbum(_ track: TrackSnapshot) throws -> BanRule {
        try addAlbum(name: track.album, artist: track.albumIdentityArtist)
    }

    @discardableResult
    public func addAlbum(name: String, artist: String) throws -> BanRule {
        let albumName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMusicText(albumName).isEmpty,
              !normalizedMusicText(albumArtist).isEmpty else {
            throw BanStoreError.incompleteAlbum
        }
        let albumKey = normalizedMusicText(albumName)
        let artistKey = normalizedMusicText(albumArtist)
        if let existing = rules.first(where: {
            $0.kind == .album && normalizedMusicText($0.name) == albumKey
                && normalizedMusicText($0.artist ?? "") == artistKey
        }) { return existing }
        let rule = BanRule(kind: .album, name: albumName, artist: albumArtist)
        try commit(rules + [rule])
        return rule
    }

    public func remove(id: UUID) throws {
        guard rules.contains(where: { $0.id == id }) else { return }
        try commit(rules.filter { $0.id != id })
    }

    /// Clears the complete saved list after the caller obtains confirmation.
    /// The in-memory list changes only after the empty document is persisted.
    public func removeAll() throws {
        guard !rules.isEmpty else { return }
        try commit([])
    }

    public func matchingRule(for track: TrackSnapshot) -> BanRule? {
        rules.first { $0.matches(track) }
    }

    private static func decodeDocument(_ data: Data) throws -> Document {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch let error as BanStoreError {
            throw error
        } catch {
            throw BanStoreError.invalidBackup
        }
        try validateRules(document.rules)
        return document
    }

    private static func validateRules(_ rules: [BanRule]) throws {
        for rule in rules {
            guard !normalizedMusicText(rule.name).isEmpty,
                  rule.kind == .artist || !normalizedMusicText(rule.artist ?? "").isEmpty,
                  rule.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  ![rule.name, rule.artist ?? "", rule.album ?? ""].contains(where: { $0.contains("\0") }) else {
                throw BanStoreError.invalidRule
            }
        }
        guard Set(rules.map(\.id)).count == rules.count else { throw BanStoreError.invalidRule }
    }

    private static func encodeDocument(_ rules: [BanRule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(rules: rules))
    }

    private func commit(_ proposedRules: [BanRule], encodedData: Data? = nil) throws {
        try Self.validateRules(proposedRules)
        let data = try encodedData ?? Self.encodeDocument(proposedRules)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        rules = proposedRules
    }
}
