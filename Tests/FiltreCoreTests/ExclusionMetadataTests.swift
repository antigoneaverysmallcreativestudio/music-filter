import Foundation
import XCTest
@testable import FiltreCore

final class ExclusionMetadataTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExclusionMetadataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("rules.json")
    }

    private func song(title: String = "Une chanson", artist: String = "Zoë", album: String = "") -> TrackSnapshot {
        TrackSnapshot(id: "metadata-test", title: title, artist: artist, album: album, isPlaying: true)
    }

    func testLegacyVersionOneRulesWithoutAlbumMetadataLoadWithoutRewriting() throws {
        let url = try temporaryFile()
        // Handwritten old schema, independent of the current Codable encoder.
        let legacy = Data(#"{"version":1,"rules":[{"id":"00000000-0000-0000-0000-000000000001","kind":"artist","name":"Zoë","createdAt":12345},{"id":"00000000-0000-0000-0000-000000000002","kind":"track","name":"Une chanson","artist":"Zoë","createdAt":12346},{"id":"00000000-0000-0000-0000-000000000003","kind":"album","name":"Nuances","artist":"Zoë","createdAt":12347}]}"#.utf8)
        try legacy.write(to: url)
        let store = try BanStore(fileURL: url)
        XCTAssertEqual(store.rules.count, 3)
        XCTAssertTrue(store.rules.allSatisfy { $0.album == nil })
        XCTAssertEqual(store.rules[1].createdAt, Date(timeIntervalSinceReferenceDate: 12346))
        XCTAssertTrue(store.rules[1].matches(song(album: "Another edition")))
        XCTAssertEqual(try Data(contentsOf: url), legacy)
    }

    func testTrackAlbumMetadataIsTrimmedAndPersists() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        let rule = try store.addTrack(song(album: "  Nuances — édition spéciale\n"))
        XCTAssertEqual(rule.album, "Nuances — édition spéciale")
        XCTAssertEqual(try BanStore(fileURL: url).rules, [rule])
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 1)
        let saved = try XCTUnwrap((document["rules"] as? [[String: Any]])?.first)
        XCTAssertEqual(saved["album"] as? String, "Nuances — édition spéciale")
    }

    func testBlankTrackAlbumMetadataRemainsNil() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        let rule = try store.addTrack(song(album: " \n\t "))
        XCTAssertNil(rule.album)
        XCTAssertNil(try BanStore(fileURL: url).rules.first?.album)
    }

    func testAlbumMetadataNeverChangesTrackMatching() {
        let rule = BanRule(kind: .track, name: "Une chanson", artist: "Zoë", album: "Nuances")
        XCTAssertTrue(rule.matches(song(album: "Nuances")))
        XCTAssertTrue(rule.matches(song(album: "A different edition")))
        XCTAssertTrue(rule.matches(song(album: "")))
        XCTAssertFalse(rule.matches(song(title: "Another song", album: "Nuances")))
        XCTAssertFalse(rule.matches(song(artist: "Another artist", album: "Nuances")))
        XCTAssertFalse(rule.matches(song(artist: "Zoe", album: "Nuances")))
        XCTAssertFalse(rule.matches(song(artist: "Zoë & Someone", album: "Nuances")))
    }

    func testDuplicateTrackEnrichesMissingAlbumPreservingIdentityDateAndWording() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        let original = try store.addTrack(song())
        let enriched = try store.addTrack(song(title: "UNE CHANSON", artist: "ZOË", album: "Nuances"))
        XCTAssertEqual(enriched.id, original.id)
        XCTAssertEqual(enriched.createdAt, original.createdAt)
        XCTAssertEqual(enriched.name, original.name)
        XCTAssertEqual(enriched.artist, original.artist)
        XCTAssertEqual(enriched.album, "Nuances")
        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(try BanStore(fileURL: url).rules, [enriched])
    }

    func testEnrichmentPreservesRuleOrderAndUnrelatedEntries() throws {
        let store = try BanStore(fileURL: temporaryFile())
        let before = try store.addArtist("First artist")
        let original = try store.addTrack(song())
        let after = try store.addAlbum(name: "Another album", artist: "Another artist")
        let enriched = try store.addTrack(song(album: "Nuances"))
        XCTAssertEqual(store.rules.map(\.id), [before.id, original.id, after.id])
        XCTAssertEqual(store.rules, [before, enriched, after])
        XCTAssertNil(before.album)
        XCTAssertNil(after.album)
    }

    func testExistingAlbumIsNotReplacedOrRewrittenForAnotherEdition() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        let original = try store.addTrack(song(album: "Original album"))
        // Make writes impossible. A duplicate with known metadata should be a
        // true no-op, even when the current song reports a different edition.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(try store.addTrack(song(album: "Other edition")), original)
        XCTAssertEqual(try store.addTrack(song(album: "Original album")), original)
        XCTAssertEqual(store.rules, [original])
    }

    func testDuplicateWithoutNewMetadataDoesNotWrite() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        let original = try store.addTrack(song())
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(try store.addTrack(song(album: " \n")), original)
        XCTAssertEqual(store.rules, [original])
    }

    func testFailedEnrichmentLeavesInMemoryRuleUnchanged() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        let original = try store.addTrack(song())
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.addTrack(song(album: "Nuances")))
        XCTAssertEqual(store.rules, [original])
        XCTAssertNil(store.rules.first?.album)
    }
}
