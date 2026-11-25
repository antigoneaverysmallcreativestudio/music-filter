import Foundation
import XCTest
@testable import FiltreCore

final class ExclusionBackupTests: XCTestCase {
    private struct Document: Encodable {
        let version: Int
        let rules: [BanRule]
    }

    private func temporaryURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicFilterBackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("exclusions.json")
    }

    private func data(_ rules: [BanRule], version: Int = 1) throws -> Data {
        try JSONEncoder().encode(Document(version: version, rules: rules))
    }

    private func fixture(_ kind: BanRule.Kind, name: String = "Example", artist: String? = "Artist",
                         album: String? = nil, id: UUID = UUID()) -> BanRule {
        BanRule(id: id, kind: kind, name: name, artist: artist, album: album,
                createdAt: Date(timeIntervalSinceReferenceDate: 12_345.5))
    }

    func testRoundTripAllKindsPreservesIdentitiesDatesAndMetadata() throws {
        let original = [fixture(.artist, name: "Beyoncé", artist: nil),
                        fixture(.album, name: "An album", artist: "A band"),
                        fixture(.track, name: "A song", artist: "A singer", album: "A release")]
        let source = try BanStore(fileURL: temporaryURL())
        XCTAssertEqual(try source.importData(data(original)).addedCount, 3)
        let exported = try source.exportedData()
        let target = try BanStore(fileURL: temporaryURL())
        let result = try target.importData(exported)
        XCTAssertEqual(result.addedCount, 3)
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertEqual(target.rules, original)
        XCTAssertEqual(try BanStore(fileURL: target.fileURL).rules, original)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(Set(document.keys), ["version", "rules"])
        XCTAssertEqual(document["version"] as? Int, 1)
    }

    func testExportDoesNotCreateOrModifyTheLocalStore() throws {
        let url = try temporaryURL()
        let store = try BanStore(fileURL: url)
        let empty = try store.exportedData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let emptyTarget = try BanStore(fileURL: temporaryURL())
        XCTAssertEqual(try emptyTarget.importData(empty).addedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyTarget.fileURL.path))
        try store.addArtist("Local artist")
        let before = try Data(contentsOf: url)
        _ = try store.exportedData()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testReadsExistingVersionOneFileWithMissingOptionalAlbum() throws {
        let rule = fixture(.track, name: "Old song", artist: "Old artist")
        let encoded = try data([rule])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\"album\""))
        let sourceURL = try temporaryURL()
        try encoded.write(to: sourceURL)
        let source = try BanStore(fileURL: sourceURL)
        let restored = try BanStore(fileURL: temporaryURL())
        try restored.importData(source.exportedData())
        XCTAssertEqual(restored.rules, [rule])
        XCTAssertNil(restored.rules.first?.album)
    }

    func testMergeNeverRemovesExistingRulesOrPromotesCollaborationsToDuplicates() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let existing = try store.addArtist("One")
        let collaboration = fixture(.artist, name: "One & Two", artist: nil)
        let result = try store.importData(data([collaboration]))
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertEqual(store.rules, [existing, collaboration])
    }

    func testDuplicatesUseCaseWhitespaceAndCanonicalUnicodeButPreserveAccents() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let existing = try store.addArtist("Maÿ Artist")
        let equivalent = fixture(.artist, name: "  MAY\u{308}\t ARTIST  ", artist: "Ignored artist field")
        let distinct = fixture(.artist, name: "May Artist", artist: nil)
        let duplicateOfIncoming = fixture(.artist, name: " MAY   artist", artist: nil)
        let result = try store.importData(data([equivalent, distinct, duplicateOfIncoming]))
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.duplicateCount, 2)
        XCTAssertEqual(store.rules, [existing, distinct])
    }

    func testDuplicateTrackKeepsExistingIDDateSpellingAndAlbum() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let original = try store.addTrack(.init(id: "1", title: "Song", artist: "Artist", album: "First release", isPlaying: false))
        let other = fixture(.track, name: " song ", artist: "ARTIST", album: "Different release")
        let before = try Data(contentsOf: store.fileURL)
        let result = try store.importData(data([other]))
        XCTAssertEqual(result.addedCount, 0)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(store.rules, [original])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testKindAndArtistAreIndependentIdentityFields() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let rules = [fixture(.artist, name: "Same", artist: nil),
                     fixture(.album, name: "Same", artist: "Same"),
                     fixture(.track, name: "Same", artist: "Same"),
                     fixture(.track, name: "Same", artist: "Another"),
                     fixture(.track, name: "A|B", artist: "C"),
                     fixture(.track, name: "A", artist: "B|C")]
        XCTAssertEqual(try store.importData(data(rules)).addedCount, rules.count)
        XCTAssertEqual(store.rules, rules)
    }

    func testConflictingLocalUUIDGetsNewIdentityWithoutReplacingEitherRule() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let local = try store.addArtist("Local")
        let incoming = fixture(.track, name: "New", artist: "Artist", album: "Album", id: local.id)
        XCTAssertEqual(try store.importData(data([incoming])).addedCount, 1)
        XCTAssertEqual(store.rules.first, local)
        let inserted = try XCTUnwrap(store.rules.last)
        XCTAssertNotEqual(inserted.id, local.id)
        XCTAssertEqual(inserted.name, incoming.name)
        XCTAssertEqual(inserted.kind, incoming.kind)
        XCTAssertEqual(inserted.artist, incoming.artist)
        XCTAssertEqual(inserted.album, incoming.album)
        XCTAssertEqual(inserted.createdAt, incoming.createdAt)
        XCTAssertEqual(try BanStore(fileURL: store.fileURL).rules, store.rules)
    }

    func testRepeatedImportsAreIdempotent() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let encoded = try data([fixture(.artist), fixture(.track), fixture(.album)])
        XCTAssertEqual(try store.importData(encoded).addedCount, 3)
        let before = try Data(contentsOf: store.fileURL)
        let result = try store.importData(encoded)
        XCTAssertEqual(result.addedCount, 0)
        XCTAssertEqual(result.duplicateCount, 3)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testInvalidEntriesRejectTheWholeImportWithoutPartialWrite() throws {
        let invalid = [fixture(.artist, name: " \n "), fixture(.track, artist: nil),
                       fixture(.album, artist: "\t"), fixture(.artist, name: "Bad\0name")]
        for bad in invalid {
            let store = try BanStore(fileURL: temporaryURL())
            let old = try store.addArtist("Existing")
            let before = try Data(contentsOf: store.fileURL)
            XCTAssertThrowsError(try store.importData(data([fixture(.artist, name: "Valid first"), bad]))) {
                XCTAssertEqual($0 as? BanStoreError, .invalidRule)
            }
            XCTAssertEqual(store.rules, [old])
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        }
    }

    func testDuplicateUUIDsInsideTheInputAreRejected() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let id = UUID()
        XCTAssertThrowsError(try store.importData(data([fixture(.artist, name: "First", id: id),
                                                      fixture(.artist, name: "Second", id: id)]))) {
            XCTAssertEqual($0 as? BanStoreError, .invalidRule)
        }
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testMalformedJSONInvalidUTF8AndUnknownRuleKindAreRejected() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let old = try store.addArtist("Existing")
        let before = try Data(contentsOf: store.fileURL)
        let valid = String(decoding: try data([fixture(.artist)]), as: UTF8.self)
        let inputs = [Data(), Data("[]".utf8), Data("not JSON".utf8), Data([0xff, 0xfe, 0x7b]),
                      Data(valid.replacingOccurrences(of: "\"kind\":\"artist\"", with: "\"kind\":\"unsupported\"").utf8)]
        for input in inputs {
            XCTAssertThrowsError(try store.importData(input)) {
                XCTAssertEqual($0 as? BanStoreError, .invalidBackup)
            }
            XCTAssertEqual(store.rules, [old])
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        }
    }

    func testFutureSchemaIsRejectedBeforeTryingToDecodeItsRules() throws {
        let store = try BanStore(fileURL: temporaryURL())
        XCTAssertThrowsError(try store.importData(Data(#"{"version":2,"rules":"future format"}"#.utf8))) {
            XCTAssertEqual($0 as? BanStoreError, .unsupportedVersion(2))
        }
        XCTAssertTrue(store.rules.isEmpty)
    }

    func testByteLimitRejectsBeforeParsingAndAcceptsExactBoundary() throws {
        let store = try BanStore(fileURL: temporaryURL())
        var atLimit = try data([])
        atLimit.append(Data(repeating: 0x20, count: BanStore.maximumImportBytes - atLimit.count))
        XCTAssertEqual(try store.importData(atLimit).addedCount, 0)
        atLimit.append(0x20)
        XCTAssertThrowsError(try store.importData(atLimit)) {
            XCTAssertEqual($0 as? BanStoreError, .backupTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testRuleLimitAppliesToIncomingAndMergedListWithoutPartialWrite() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let full = (0..<BanStore.maximumImportRules).map { fixture(.artist, name: "Artist \($0)", artist: nil) }
        XCTAssertEqual(try store.importData(data(full)).addedCount, full.count)
        let before = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.importData(data([fixture(.artist, name: "One extra", artist: nil)]))) {
            XCTAssertEqual($0 as? BanStoreError, .tooManyBackupRules)
        }
        XCTAssertThrowsError(try store.importData(data(full + [fixture(.artist, name: "Another", artist: nil)]))) {
            XCTAssertEqual($0 as? BanStoreError, .tooManyBackupRules)
        }
        XCTAssertEqual(store.rules, full)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testMergedEncodedByteLimitKeepsTheOldListUnchanged() throws {
        let store = try BanStore(fileURL: temporaryURL())
        let huge = fixture(.artist, name: String(repeating: "a", count: 3 * 1024 * 1024), artist: nil)
        try store.importData(data([huge]))
        let before = try Data(contentsOf: store.fileURL)
        let second = fixture(.artist, name: String(repeating: "b", count: 3 * 1024 * 1024), artist: nil)
        XCTAssertThrowsError(try store.importData(data([second]))) {
            XCTAssertEqual($0 as? BanStoreError, .backupTooLarge)
        }
        XCTAssertEqual(store.rules, [huge])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testFailedPersistenceDoesNotModifyInMemoryRules() throws {
        let url = try temporaryURL()
        let store = try BanStore(fileURL: url)
        let existing = try store.addArtist("Existing")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let sentinel = url.appendingPathComponent("keep.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        XCTAssertThrowsError(try store.importData(data([fixture(.artist, name: "New")])))
        XCTAssertEqual(store.rules, [existing])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
    }

    func testNoOpImportDoesNotAttemptPersistence() throws {
        let url = try temporaryURL()
        let store = try BanStore(fileURL: url)
        let existing = try store.addArtist("Existing")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let duplicate = fixture(.artist, name: "EXISTING", artist: nil)
        XCTAssertEqual(try store.importData(data([duplicate])).duplicateCount, 1)
        XCTAssertEqual(try store.importData(data([])).addedCount, 0)
        XCTAssertEqual(store.rules, [existing])
    }
}
