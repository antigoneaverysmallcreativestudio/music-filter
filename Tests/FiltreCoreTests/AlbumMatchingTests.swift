import Foundation
import XCTest
@testable import FiltreCore

final class AlbumMatchingTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MusicFilterAlbumTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("exclusions.json")
    }

    func testAlbumRuleCoversDifferentTracksAndCreditsUsingAlbumArtist() throws {
        let store = try BanStore(fileURL: temporaryFile())
        let first = TrackSnapshot(id: "a", title: "Opening", artist: "Lead feat. Guest", albumArtist: "Lead", album: "The Album", isPlaying: true)
        let rule = try store.addAlbum(first)
        XCTAssertEqual(rule.kind, .album)
        XCTAssertEqual(rule.name, "The Album")
        XCTAssertEqual(rule.artist, "Lead")
        let second = TrackSnapshot(id: "b", title: "Another song", artist: "Lead", albumArtist: "Lead", album: "The Album", isPlaying: true)
        let third = TrackSnapshot(id: "c", title: "Closing", artist: "Different credited singer", albumArtist: "Lead", album: "The Album", isPlaying: false)
        XCTAssertEqual(store.matchingRule(for: second), rule)
        XCTAssertEqual(store.matchingRule(for: third), rule)
    }

    func testAlbumNameAndAlbumArtistMustBothMatchExactly() throws {
        let store = try BanStore(fileURL: temporaryFile())
        let rule = try store.addAlbum(name: "Home", artist: "Maÿ")
        let differentAlbum = TrackSnapshot(id: "a", title: "Song", artist: "Maÿ", albumArtist: "Maÿ", album: "Home Deluxe", isPlaying: true)
        let differentArtist = TrackSnapshot(id: "b", title: "Song", artist: "Other", albumArtist: "May", album: "Home", isPlaying: true)
        let matchingTrackArtistButDifferentAlbumArtist = TrackSnapshot(id: "c", title: "Song", artist: "Maÿ", albumArtist: "Other", album: "Home", isPlaying: true)
        XCTAssertNil(store.matchingRule(for: differentAlbum))
        XCTAssertNil(store.matchingRule(for: differentArtist))
        XCTAssertNil(store.matchingRule(for: matchingTrackArtistButDifferentAlbumArtist))
        let canonical = TrackSnapshot(id: "d", title: "Song", artist: "Guest", albumArtist: "MAY\u{308}", album: " HOME\n", isPlaying: true)
        XCTAssertEqual(store.matchingRule(for: canonical), rule)
    }

    func testMissingAlbumArtistFallsBackToTrackCreditWithoutBroadening() throws {
        let store = try BanStore(fileURL: temporaryFile())
        let first = TrackSnapshot(id: "a", title: "First", artist: "Lead", albumArtist: " \n", album: "Record", isPlaying: true)
        let rule = try store.addAlbum(first)
        XCTAssertEqual(first.albumIdentityArtist, "Lead")
        XCTAssertEqual(rule.artist, "Lead")
        let sameCredit = TrackSnapshot(id: "b", title: "Second", artist: "Lead", album: "Record", isPlaying: true)
        let otherCredit = TrackSnapshot(id: "c", title: "Third", artist: "Guest", album: "Record", isPlaying: true)
        XCTAssertEqual(store.matchingRule(for: sameCredit), rule)
        XCTAssertNil(store.matchingRule(for: otherCredit))
    }

    func testCompilationAlbumCreditCoversAllItsArtistsButNotOtherAlbums() throws {
        let store = try BanStore(fileURL: temporaryFile())
        let first = TrackSnapshot(id: "a", title: "First", artist: "One artist", albumArtist: "Various Artists", album: "Compilation One", isPlaying: true)
        let rule = try store.addAlbum(first)
        XCTAssertEqual(rule.artist, "Various Artists")
        let otherArtistSameAlbum = TrackSnapshot(id: "b", title: "Second", artist: "Another artist", albumArtist: "VARIOUS ARTISTS", album: "Compilation One", isPlaying: true)
        let otherCompilation = TrackSnapshot(id: "c", title: "Third", artist: "One artist", albumArtist: "Various Artists", album: "Compilation Two", isPlaying: true)
        XCTAssertEqual(store.matchingRule(for: otherArtistSameAlbum), rule)
        XCTAssertNil(store.matchingRule(for: otherCompilation))
        XCTAssertNil(store.matchingRule(for: .init(id: "d", title: "First", artist: "One artist", albumArtist: "Lead", album: "Compilation One", isPlaying: true)))
    }

    func testFrenchCompilationCreditIsAnExplicitAlbumIdentity() throws {
        let store = try BanStore(fileURL: temporaryFile())
        let rule = try store.addAlbum(name: "Festival", artist: "Multi-interprètes")
        XCTAssertEqual(store.matchingRule(for: .init(id: "a", title: "Song", artist: "Singer", albumArtist: "Multi-interprètes", album: "Festival", isPlaying: true)), rule)
        XCTAssertNil(store.matchingRule(for: .init(id: "b", title: "Song", artist: "Singer", albumArtist: "Multi-interprètes", album: "Another festival", isPlaying: true)))
    }

    func testAlbumDeduplicationUsesAlbumAndArtistAndSurvivesReload() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        let first = try store.addAlbum(name: " Résumé ", artist: "Maÿ")
        let equivalent = TrackSnapshot(id: "a", title: "Different song", artist: "Guest", albumArtist: "MAY\u{308}", album: " RE\u{301}SUME\u{301} ", isPlaying: true)
        XCTAssertEqual(try store.addAlbum(equivalent).id, first.id)
        let otherArtist = try store.addAlbum(name: "Résumé", artist: "May")
        let otherAlbum = try store.addAlbum(name: "Resume", artist: "Maÿ")
        XCTAssertNotEqual(otherArtist.id, first.id)
        XCTAssertNotEqual(otherAlbum.id, first.id)
        XCTAssertEqual(store.rules.count, 3)
        XCTAssertEqual(try BanStore(fileURL: url).rules, store.rules)
        try store.remove(id: first.id)
        XCTAssertEqual(try BanStore(fileURL: url).rules.count, 2)
    }

    func testMissingAlbumOrIdentityCannotCreateOrMatchAlbumRule() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        XCTAssertThrowsError(try store.addAlbum(.init(id: "a", title: "Song", artist: "Singer", isPlaying: true)))
        XCTAssertThrowsError(try store.addAlbum(.init(id: "b", title: "Song", artist: "", album: "Record", isPlaying: true)))
        XCTAssertThrowsError(try store.addAlbum(name: " \n", artist: "Singer"))
        XCTAssertThrowsError(try store.addAlbum(name: "Record", artist: "\t "))
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let rule = BanRule(kind: .album, name: "Record", artist: "Singer")
        XCTAssertFalse(rule.matches(.init(id: "c", title: "Record", artist: "Singer", isPlaying: true)))
        XCTAssertFalse(rule.matches(.init(id: "d", title: "Song", artist: "", album: "Record", isPlaying: true)))
        XCTAssertFalse(BanRule(kind: .album, name: "Record").matches(.init(id: "e", title: "Song", artist: "Singer", album: "Record", isPlaying: true)))
    }

    func testAutomaticArtistCollaborationsDoNotExpandAlbumIdentity() throws {
        let store = try BanStore(fileURL: temporaryFile())
        try store.addAlbum(name: "Record", artist: "Guest")
        let featuredCredit = TrackSnapshot(id: "a", title: "Song (feat. Guest)", artist: "Lead feat. Guest", albumArtist: "Lead", album: "Record", isPlaying: true)
        XCTAssertNil(store.matchingRule(for: featuredCredit))
        let guestOnlyOnTrack = TrackSnapshot(id: "b", title: "Song", artist: "Guest", albumArtist: "Lead", album: "Record", isPlaying: true)
        XCTAssertNil(store.matchingRule(for: guestOnlyOnTrack))
        let noAlbumCredit = TrackSnapshot(id: "c", title: "Song", artist: "Lead feat. Guest", album: "Record", isPlaying: true)
        XCTAssertNil(store.matchingRule(for: noAlbumCredit))
        let exactAlbum = TrackSnapshot(id: "d", title: "Song (feat. Other)", artist: "Guest feat. Other", albumArtist: "Guest", album: "Record", isPlaying: true)
        XCTAssertNotNil(store.matchingRule(for: exactAlbum))
        let differentAlbum = TrackSnapshot(id: "e", title: "Song", artist: "Guest", albumArtist: "Guest", album: "Another Record", isPlaying: true)
        XCTAssertNil(store.matchingRule(for: differentAlbum))
    }

    func testLegacyVersionOneRulesLoadAndRemainUnchangedAfterAddingAlbum() throws {
        let url = try temporaryFile()
        let original = #"{"version":1,"rules":[{"id":"00000000-0000-0000-0000-000000000001","kind":"artist","name":"Legacy Singer","createdAt":42},{"id":"00000000-0000-0000-0000-000000000002","kind":"track","name":"Legacy Song","artist":"Another Singer","createdAt":43}]}"#
        try Data(original.utf8).write(to: url)
        let store = try BanStore(fileURL: url)
        let previousRules = store.rules
        XCTAssertEqual(previousRules.map(\.kind), [.artist, .track])
        try store.addAlbum(name: "New Album", artist: "New Singer")
        let reloaded = try BanStore(fileURL: url)
        XCTAssertEqual(Array(reloaded.rules.prefix(2)), previousRules)
        XCTAssertEqual(reloaded.rules.last?.kind, .album)
        XCTAssertNotNil(reloaded.matchingRule(for: .init(id: "a", title: "Any song", artist: "Legacy Singer", isPlaying: true)))
        XCTAssertNotNil(reloaded.matchingRule(for: .init(id: "b", title: "Legacy Song", artist: "Another Singer", isPlaying: true)))
    }

    func testInvalidPersistedAlbumWithoutArtistIsRejectedWithoutOverwrite() throws {
        let url = try temporaryFile()
        let original = #"{"version":1,"rules":[{"id":"00000000-0000-0000-0000-000000000001","kind":"album","name":"Record","createdAt":42}]}"#
        let data = Data(original.utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try BanStore(fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testAlbumWriteFailureLeavesMemoryUnchanged() throws {
        let blocker = try temporaryFile()
        try Data("not a folder".utf8).write(to: blocker)
        let store = try BanStore(fileURL: blocker.appendingPathComponent("rules.json"))
        XCTAssertThrowsError(try store.addAlbum(name: "Record", artist: "Singer"))
        XCTAssertTrue(store.rules.isEmpty)
    }

    func testTrackIdentityDistinguishesAlbumsDespitePlaceholderTrackID() {
        let first = TrackSnapshot(id: "0000000000000000", title: "Intro", artist: "Singer", album: "First", isPlaying: true)
        let second = TrackSnapshot(id: "0000000000000000", title: "Intro", artist: "Singer", album: "Second", isPlaying: true)
        XCTAssertNotEqual(first.identity, second.identity)
    }
}
