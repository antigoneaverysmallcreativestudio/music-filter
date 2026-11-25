import Foundation
import XCTest
@testable import FiltreCore

final class CollaborationMatchingTests: XCTestCase {
    private let blockedArtist = BanRule(kind: .artist, name: "MAŸ")

    private func track(artist: String = "Someone Else", title: String = "A Song", albumArtist: String = "") -> TrackSnapshot {
        TrackSnapshot(id: "track", title: title, artist: artist, albumArtist: albumArtist, isPlaying: true)
    }

    func testArtistRulesAutomaticallyIncludeRecognizedCollaborations() {
        XCTAssertTrue(blockedArtist.matches(track(artist: "55ASKY & MAŸ")))
        XCTAssertTrue(blockedArtist.matches(track(artist: "55ASKY feat. MAŸ")))
        XCTAssertTrue(blockedArtist.matches(track(title: "A Song (feat. MAŸ)")))
        XCTAssertTrue(blockedArtist.matches(track(artist: "Maÿ")))
    }

    func testRecognizesWholeJointCreditsInEitherPosition() {
        for credit in ["55ASKY & MAŸ", "MAŸ & 55ASKY", "55ASKY + MAŸ", "55ASKY x MAŸ",
                       "55ASKY × MAŸ", "First & Maÿ & Third", "55ASKY\t&\tMAY\u{308}"] {
            XCTAssertTrue(blockedArtist.matches(track(artist: credit)), credit)
        }
    }

    func testRecognizesExplicitArtistFeatures() {
        for credit in ["55ASKY feat. MAŸ", "55ASKY feat MAŸ", "55ASKY ft. MAŸ", "55ASKY FT MAŸ",
                       "55ASKY featuring MAŸ", "55ASKY (feat. MAŸ)", "55ASKY [ft. MAŸ]",
                       "55ASKY ( feat. MAŸ )", "55ASKY feat. Other & MAŸ"] {
            XCTAssertTrue(blockedArtist.matches(track(artist: credit)), credit)
        }
        XCTAssertTrue(BanRule(kind: .artist, name: "55ASKY").matches(track(artist: "55ASKY (feat. MAŸ)")))
    }

    func testOnlyBracketedFeatureAnnotationsCountInTitles() {
        for title in ["A Song (feat. MAŸ)", "A Song [ft. Maÿ]", "A Song (FEATURING MAŸ) - Remix",
                      "A Song (feat. First & MAŸ)", "A Song (feat. First) [ft. MAŸ]"] {
            XCTAssertTrue(blockedArtist.matches(track(title: title)), title)
        }
        for title in ["MAŸ", "A Song for MAŸ", "A Song & MAŸ", "A Song feat. MAŸ", "A Song (with MAŸ)",
                      "A Song (feat. MAŸ]", "A Song (defeated MAŸ)", "A Song (feat. MAŸ Jr.)"] {
            XCTAssertFalse(blockedArtist.matches(track(title: title)), title)
        }
    }

    func testPreservesAccentsAndWholeNames() {
        for credit in ["May", "55ASKY & May", "MAŸ Jr.", "55ASKY & MAŸ Jr.", "NotMAŸ", "55ASKY & NotMAŸ"] {
            XCTAssertFalse(blockedArtist.matches(track(artist: credit)), credit)
        }
        let fire = BanRule(kind: .artist, name: "Fire")
        XCTAssertFalse(fire.matches(track(artist: "Bonfire")))
        XCTAssertFalse(fire.matches(track(artist: "Other & Bonfire")))
        let may = BanRule(kind: .artist, name: "May")
        XCTAssertFalse(may.matches(track(artist: "55ASKY & MAŸ")))
    }

    func testNoAlbumArtistOrGeneralPunctuationInference() {
        XCTAssertFalse(blockedArtist.matches(track(albumArtist: "MAŸ")))
        for credit in ["55ASKY, MAŸ", "55ASKY and MAŸ", "55ASKY / MAŸ", "55ASKY&MAŸ", "55ASKY+MAŸ"] {
            XCTAssertFalse(blockedArtist.matches(track(artist: credit)), credit)
        }
    }

    func testWholeArtistNamesContainingSeparatorsRemainMatchable() {
        let band = BanRule(kind: .artist, name: "Earth, Wind & Fire")
        XCTAssertTrue(band.matches(track(artist: "Earth, Wind & Fire")))
        XCTAssertTrue(band.matches(track(artist: "Earth, Wind & Fire & MAŸ")))
        let punctuation = BanRule(kind: .artist, name: "(hed) p.e.")
        XCTAssertTrue(punctuation.matches(track(artist: "(hed) p.e. & Other")))
    }

    func testNameOnlyMetadataCannotDisambiguateBandNamesFromJointCredits() {
        // Honest boundary of name-only metadata: a spaced ampersand is a
        // recognized joint-credit separator, even within some band names.
        XCTAssertTrue(BanRule(kind: .artist, name: "Fire").matches(
            track(artist: "Earth, Wind & Fire")))
    }

    func testSongRulesStayExactDespiteAutomaticArtistCollaborationMatching() {
        let song = BanRule(kind: .track, name: "A Song", artist: "MAŸ")
        XCTAssertTrue(song.matches(track(artist: "MAŸ")))
        XCTAssertFalse(song.matches(track(artist: "MAŸ & Other")))
        XCTAssertFalse(song.matches(track(artist: "Other feat. MAŸ")))
        XCTAssertFalse(song.matches(track(artist: "MAŸ", title: "A Song (feat. Other)")))
        XCTAssertFalse(song.matches(track(artist: "MAŸ", title: "Another Song")))
        let featuredSong = BanRule(kind: .track, name: "A Song (feat. MAŸ)", artist: "Lead")
        XCTAssertTrue(featuredSong.matches(track(artist: "Lead", title: "A Song (feat. MAŸ)")))
        XCTAssertFalse(featuredSong.matches(track(artist: "MAŸ", title: "A Song (feat. MAŸ)")))
        XCTAssertFalse(featuredSong.matches(track(artist: "Lead", title: "Another Song (feat. MAŸ)")))
    }

    func testStoreMatchesCollaborationsWithoutChangingSavedRules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rules.json")
        let store = try BanStore(fileURL: url)
        let rule = try store.addArtist("MAŸ")
        let savedData = try Data(contentsOf: url)
        let collaboration = track(artist: "55ASKY & MAŸ")
        XCTAssertEqual(store.matchingRule(for: collaboration)?.id, rule.id)
        XCTAssertEqual(store.rules, [rule])
        XCTAssertEqual(try Data(contentsOf: url), savedData)
    }

    func testLegacyRulesGainArtistCollaborationMatchingWithoutRewritingJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rules.json")
        let original = #"{"version":1,"rules":[{"id":"00000000-0000-0000-0000-000000000001","kind":"artist","name":"MAŸ","createdAt":42}]}"#
        let data = Data(original.utf8)
        try data.write(to: url)
        let store = try BanStore(fileURL: url)
        XCTAssertEqual(store.matchingRule(for: track(artist: "Lead feat. MAŸ"))?.name, "MAŸ")
        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules.first?.id.uuidString, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
