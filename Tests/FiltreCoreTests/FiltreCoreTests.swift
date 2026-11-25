import Foundation
import XCTest
@testable import FiltreCore

final class BanStoreTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FiltreCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("rules.json")
    }

    func testPersistenceDeduplicatesAndRemovesRules() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        let artist = try store.addArtist("  Beyoncé  ")
        XCTAssertEqual(try store.addArtist("BEYONCE\u{301}").id, artist.id)
        let track = TrackSnapshot(id: "1", title: "Une chanson", artist: "Autre artiste", isPlaying: true)
        let song = try store.addTrack(track)
        XCTAssertEqual(try store.addTrack(track).id, song.id)
        XCTAssertEqual(store.rules.count, 2)
        let reloaded = try BanStore(fileURL: url)
        XCTAssertEqual(reloaded.rules, store.rules)
        try reloaded.remove(id: artist.id)
        XCTAssertEqual(try BanStore(fileURL: url).rules.map(\.id), [song.id])
    }

    func testArtistMatchAvoidsSubstringsAndAlbumArtistButIncludesFeatures() throws {
        let store = try BanStore(fileURL: temporaryFile())
        try store.addArtist("Sting")
        try store.addArtist("Fire")
        try store.addArtist("Various Artists")
        let tracks = [
            TrackSnapshot(id: "a", title: "A", artist: "Stingray", isPlaying: true),
            TrackSnapshot(id: "b", title: "B", artist: "Earth, Wind & Bonfire", isPlaying: true),
            TrackSnapshot(id: "c", title: "C", artist: "Un artiste", albumArtist: "Various Artists", isPlaying: true)
        ]
        for track in tracks { XCTAssertNil(store.matchingRule(for: track)) }
        XCTAssertNotNil(store.matchingRule(for: .init(id: "d", title: "D", artist: "Un artiste feat. Sting", isPlaying: true)))
        XCTAssertNotNil(store.matchingRule(for: .init(id: "e", title: "E", artist: " STING\n", isPlaying: false)))
    }

    func testUnicodeAndWhitespaceNormalization() throws {
        let store = try BanStore(fileURL: temporaryFile())
        try store.addArtist("Beyoncé Knowles")
        let track = TrackSnapshot(id: "a", title: "A", artist: " beyonce\u{301}\t \nKNOWLES ", isPlaying: true)
        XCTAssertNotNil(store.matchingRule(for: track))
    }

    func testArtistDiacriticsRemainSignificant() throws {
        let store = try BanStore(fileURL: temporaryFile())
        let mayWithDiaeresis = try store.addArtist("Maÿ")
        XCTAssertEqual(try store.addArtist("MAY\u{308}").id, mayWithDiaeresis.id)
        XCTAssertNotNil(store.matchingRule(for: .init(id: "a", title: "A", artist: "Maÿ", isPlaying: true)))
        XCTAssertNotNil(store.matchingRule(for: .init(id: "b", title: "B", artist: "MAY\u{308}", isPlaying: true)))
        XCTAssertNil(store.matchingRule(for: .init(id: "c", title: "C", artist: "May", isPlaying: true)))
        let mayWithoutDiaeresis = try store.addArtist("May")
        XCTAssertNotEqual(mayWithoutDiaeresis.id, mayWithDiaeresis.id)
        try store.addArtist("Beyoncé")
        XCTAssertNil(store.matchingRule(for: .init(id: "d", title: "D", artist: "Beyonce", isPlaying: true)))
    }

    func testTrackRequiresSameTitleAndArtist() throws {
        let store = try BanStore(fileURL: temporaryFile())
        let original = TrackSnapshot(id: "a", title: "Intro", artist: "Premier", isPlaying: true)
        try store.addTrack(original)
        XCTAssertNotNil(store.matchingRule(for: .init(id: "different-id", title: "INTRO", artist: "premier", isPlaying: true)))
        XCTAssertNil(store.matchingRule(for: .init(id: "b", title: "Intro", artist: "Second", isPlaying: true)))
        XCTAssertNil(store.matchingRule(for: .init(id: "c", title: "Introduction", artist: "Premier", isPlaying: true)))
    }

    func testEmptyMetadataCannotCreateRules() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        XCTAssertThrowsError(try store.addArtist(" \n "))
        XCTAssertThrowsError(try store.addTrack(.init(id: "a", title: "", artist: "Artiste", isPlaying: true)))
        XCTAssertThrowsError(try store.addTrack(.init(id: "a", title: "Titre", artist: "", isPlaying: true)))
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedAddDoesNotClaimRuleWasSaved() throws {
        let blocker = try temporaryFile()
        try Data("a file, not a directory".utf8).write(to: blocker)
        let store = try BanStore(fileURL: blocker.appendingPathComponent("rules.json"))
        XCTAssertThrowsError(try store.addArtist("Un artiste"))
        XCTAssertTrue(store.rules.isEmpty)
    }

    func testFailedRemoveKeepsInMemoryRule() throws {
        let url = try temporaryFile()
        let store = try BanStore(fileURL: url)
        let rule = try store.addArtist("Un artiste")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.remove(id: rule.id))
        XCTAssertEqual(store.rules, [rule])
    }

    func testMalformedFileRemainsUntouched() throws {
        let url = try temporaryFile()
        let corruptData = Data("not JSON".utf8)
        try corruptData.write(to: url)
        XCTAssertThrowsError(try BanStore(fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), corruptData)
    }

    func testFutureSchemaIsRejected() throws {
        let url = try temporaryFile()
        try Data(#"{"version":2,"rules":[]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try BanStore(fileURL: url)) { error in
            XCTAssertEqual(error as? BanStoreError, .unsupportedVersion(2))
        }
    }

    func testInvalidPersistedRuleIsRejected() throws {
        let url = try temporaryFile()
        let invalid = BanRule(kind: .track, name: "A title", artist: nil)
        struct Document: Encodable { let version = 1; let rules: [BanRule] }
        try JSONEncoder().encode(Document(rules: [invalid])).write(to: url)
        XCTAssertThrowsError(try BanStore(fileURL: url))
    }

    func testSnapshotIdentityDoesNotConflateArtistAndTitle() {
        let first = TrackSnapshot(id: "", title: "c", artist: "ab", isPlaying: true)
        let second = TrackSnapshot(id: "", title: "bc", artist: "a", isPlaying: true)
        XCTAssertNotEqual(first.identity, second.identity)
    }

    func testSnapshotIdentityIncludesMetadataWhenIDIsAPlaceholder() {
        let first = TrackSnapshot(id: "0000000000000000", title: "First song", artist: "Maÿ", isPlaying: true)
        let second = TrackSnapshot(id: "0000000000000000", title: "Second song", artist: "Maÿ", isPlaying: true)
        let third = TrackSnapshot(id: "0000000000000000", title: "First song", artist: "May", isPlaying: true)
        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertNotEqual(first.identity, third.identity)
        var gate = SkipGate()
        XCTAssertEqual(gate.evaluate(trackID: first.identity, isBlocked: true, isPlaying: true), .skip)
        XCTAssertEqual(gate.evaluate(trackID: first.identity, isBlocked: true, isPlaying: true), .none)
        XCTAssertEqual(gate.evaluate(trackID: second.identity, isBlocked: true, isPlaying: true), .skip)
    }

    func testSnapshotIdentityRemainsStableForEquivalentMetadata() {
        let first = TrackSnapshot(id: "1", title: "A song", artist: "Maÿ", isPlaying: true)
        let equivalent = TrackSnapshot(id: "1", title: " A\tSONG ", artist: "MAY\u{308}", isPlaying: false)
        XCTAssertEqual(first.identity, equivalent.identity)
    }
}

final class SkipGateTests: XCTestCase {
    func testStaleBlockedTrackOnlySkipsOnce() {
        var gate = SkipGate()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true, now: now), .skip)
        for offset in 1...40 {
            XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true, now: now.addingTimeInterval(Double(offset))), .none)
        }
    }

    func testAllowedTrackSeparatesRepeatedBlockedOccurrences() {
        var gate = SkipGate()
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true), .skip)
        XCTAssertEqual(gate.evaluate(trackID: "B", isBlocked: false, isPlaying: true), .none)
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true), .skip)
    }

    func testPausedAndMissingTracksNeverSkip() {
        var gate = SkipGate()
        XCTAssertEqual(gate.evaluate(trackID: "", isBlocked: true, isPlaying: true), .none)
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: false), .none)
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true), .skip)
    }

    func testPauseResumeDoesNotRetrySameOccurrenceWithoutExplicitReset() {
        var gate = SkipGate()
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true), .skip)
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: false), .none)
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true), .none)
        gate.reset()
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true), .skip)
    }

    func testNinthRapidSkipRequestsPauseUntilExplicitReset() {
        var gate = SkipGate()
        let now = Date(timeIntervalSince1970: 100)
        for index in 0..<8 {
            XCTAssertEqual(gate.evaluate(trackID: "\(index)", isBlocked: true, isPlaying: true, now: now.addingTimeInterval(Double(index))), .skip)
        }
        XCTAssertEqual(gate.evaluate(trackID: "ninth", isBlocked: true, isPlaying: true, now: now.addingTimeInterval(9)), .requiresPause)
        XCTAssertEqual(gate.evaluate(trackID: "tenth", isBlocked: true, isPlaying: true, now: now.addingTimeInterval(90)), .requiresPause)
        gate.reset()
        XCTAssertEqual(gate.evaluate(trackID: "ninth", isBlocked: true, isPlaying: true, now: now.addingTimeInterval(91)), .skip)
    }

    func testRateLimitUsesRollingWindow() {
        var gate = SkipGate(maximumSkips: 2, window: 30)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(gate.evaluate(trackID: "A", isBlocked: true, isPlaying: true, now: now), .skip)
        XCTAssertEqual(gate.evaluate(trackID: "B", isBlocked: true, isPlaying: true, now: now.addingTimeInterval(1)), .skip)
        XCTAssertEqual(gate.evaluate(trackID: "C", isBlocked: true, isPlaying: true, now: now.addingTimeInterval(30)), .skip)
    }
}

final class MusicLinkTests: XCTestCase {
    func testSharedSongUsesIQueryInsteadOfAlbumID() throws {
        let link = try XCTUnwrap(MusicLink(string: "https://music.apple.com/fr/album/nom-album/123?i=456&ls=1"))
        XCTAssertEqual(link.kind, .song)
        XCTAssertEqual(link.catalogID, "456")
        XCTAssertEqual(link.countryCode, "fr")
    }

    func testAlbumIsNotSilentlyTreatedAsSong() throws {
        let link = try XCTUnwrap(MusicLink(string: "https://music.apple.com/fr/album/nom-album/123"))
        XCTAssertEqual(link.kind, .album)
        XCTAssertEqual(link.catalogID, "123")
    }

    func testArtistAndDirectSongLinks() throws {
        let artist = try XCTUnwrap(MusicLink(string: "https://music.apple.com/fr/artist/nom-artiste/123"))
        XCTAssertEqual(artist.kind, .artist)
        let song = try XCTUnwrap(MusicLink(string: "https://music.apple.com/song/456"))
        XCTAssertEqual(song.kind, .song)
        XCTAssertNil(song.countryCode)
    }

    func testLegacyITunesIDPrefix() throws {
        let link = try XCTUnwrap(MusicLink(string: "https://itunes.apple.com/FR/album/nom/id123?i=456"))
        XCTAssertEqual(link.catalogID, "456")
        XCTAssertEqual(link.countryCode, "fr")
        XCTAssertEqual(MusicLink(string: "https://itunes.apple.com/us/artist/name/id123")?.catalogID, "123")
    }

    func testUntrustedAndAmbiguousLinksAreRejected() {
        let invalid = [
            "http://music.apple.com/fr/song/a/123",
            "https://music.apple.com.evil.example/fr/song/a/123",
            "https://music.apple.com@evil.example/fr/song/a/123",
            "https://user@music.apple.com/fr/song/a/123",
            "https://music.apple.com:444/fr/song/a/123",
            "https://example.com/fr/song/a/123",
            "https://music.apple.com/fr/album/a/123?i=456&i=789",
            "https://music.apple.com/fr/artist/a/123?i=456",
            "https://music.apple.com/fr/song/a/123?i=456",
            "https://music.apple.com/fr/album/a/123?i=not-a-number",
            "https://music.apple.com/fr/playlist/a/pl.123",
            "https://music.apple.com/fr/song/a/0",
            "https://music.apple.com/fr/song/a/-123",
            "https://music.apple.com/fr/song/a/99999999999999999999999999999999"
        ]
        for string in invalid { XCTAssertNil(MusicLink(string: string), string) }
    }
}
