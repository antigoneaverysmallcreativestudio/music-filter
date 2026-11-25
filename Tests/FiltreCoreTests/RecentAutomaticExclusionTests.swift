import XCTest
@testable import FiltreCore

final class RecentAutomaticExclusionTests: XCTestCase {
    func testNoSongBeforeTheFirstAutomaticExclusion() {
        let recent = RecentAutomaticExclusion()
        XCTAssertNil(recent.song(at: 100))
    }

    func testSongStaysAvailableUntilAnotherAutomaticExclusion() {
        var recent = RecentAutomaticExclusion()
        recent.record(title: "On verra", artist: "Angèle", at: 100)

        for time in [100.0, 130, 3_700, 86_500] {
            XCTAssertEqual(recent.song(at: time)?.title, "On verra")
            XCTAssertEqual(recent.song(at: time)?.artist, "Angèle")
            XCTAssertEqual(recent.song(at: time)?.displayName, "Angèle — On verra")
        }
    }

    func testNewAutomaticExclusionReplacesTheSong() {
        var recent = RecentAutomaticExclusion()
        recent.record(title: "On verra", artist: "Angèle", at: 100)
        recent.record(title: "Saxophone", artist: "Odezenne", at: 120)

        for time in [130.0, 86_500] {
            XCTAssertEqual(recent.song(at: time)?.title, "Saxophone")
            XCTAssertEqual(recent.song(at: time)?.artist, "Odezenne")
            XCTAssertEqual(recent.song(at: time)?.displayName, "Odezenne — Saxophone")
        }
    }

    func testDisplayTitleKeepsItsSpellingAndOnlyTrimsTheEdges() {
        var recent = RecentAutomaticExclusion()
        recent.record(title: " \n Été  (Live)\t ", artist: " \n MAŸ &  Zoë\t ", at: 100)

        XCTAssertEqual(recent.song(at: 100)?.title, "Été  (Live)")
        XCTAssertEqual(recent.song(at: 100)?.artist, "MAŸ &  Zoë")
        XCTAssertEqual(recent.song(at: 100)?.displayName, "MAŸ &  Zoë — Été  (Live)")
    }

    func testBlankMetadataDoesNotEraseTheLastValidSong() {
        var recent = RecentAutomaticExclusion()
        recent.record(title: " \t\n", artist: "Odezenne", at: 90)
        XCTAssertNil(recent.song(at: 90))

        recent.record(title: "On verra", artist: "Angèle", at: 100)
        recent.record(title: "", artist: "Odezenne", at: 120)
        recent.record(title: " \t\n", artist: "Odezenne", at: 129)
        XCTAssertEqual(recent.song(at: 129)?.displayName, "Angèle — On verra")
        XCTAssertEqual(recent.song(at: 86_500)?.displayName, "Angèle — On verra")

        // A missing artist still leaves an identifiable song, without a
        // dangling separator or an invented artist credit.
        recent.record(title: "Instrumental", artist: " \t\n", at: 86_600)
        XCTAssertEqual(recent.song(at: 86_600)?.title, "Instrumental")
        XCTAssertEqual(recent.song(at: 86_600)?.artist, "")
        XCTAssertEqual(recent.song(at: 86_600)?.displayName, "Instrumental")
    }

    func testOlderEventCannotReplaceTheMostRecentAutomaticExclusion() {
        var recent = RecentAutomaticExclusion()
        recent.record(title: "Saxophone", artist: "Odezenne", at: 120)
        recent.record(title: "On verra", artist: "Angèle", at: 100)

        XCTAssertEqual(recent.song(at: 130)?.displayName, "Odezenne — Saxophone")
        XCTAssertEqual(recent.song(at: 86_500)?.displayName, "Odezenne — Saxophone")
        XCTAssertNil(recent.song(at: 119))
    }

    func testInvalidClockValuesCannotCreateOrReplaceAnEntry() {
        var recent = RecentAutomaticExclusion()
        recent.record(title: "On verra", artist: "Angèle", at: .nan)
        XCTAssertNil(recent.song(at: 100))

        recent.record(title: "Haut les cœurs", artist: "Odezenne", at: 100)
        recent.record(title: "On verra", artist: "Angèle", at: .infinity)
        XCTAssertEqual(recent.song(at: 129)?.displayName, "Odezenne — Haut les cœurs")
        XCTAssertEqual(recent.song(at: 86_500)?.displayName, "Odezenne — Haut les cœurs")
        XCTAssertNil(recent.song(at: .nan))
        XCTAssertNil(recent.song(at: .infinity))
    }
}
