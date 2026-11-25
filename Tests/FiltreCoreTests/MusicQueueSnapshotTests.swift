import XCTest
@testable import FiltreCore

final class QueueTrackMetadataTests: XCTestCase {
    func testParsesOnlyStructurallySeparatedTitleAndCredit() throws {
        let metadata = try XCTUnwrap(QueueTrackMetadata(accessibilityValue: " Un morceau \n Maÿ — Premier album "))
        XCTAssertEqual(metadata.title, "Un morceau")
        XCTAssertEqual(metadata.artist, "Maÿ")
        XCTAssertEqual(metadata.album, "Premier album")
        XCTAssertFalse(metadata.trackSnapshot.isPlaying)
        XCTAssertEqual(metadata.trackSnapshot.albumArtist, "")
        XCTAssertTrue(metadata.trackSnapshot.id.hasPrefix("queue:"))
    }

    func testCRLFAndNonbreakingCreditSpacesRemainUnambiguous() throws {
        let metadata = try XCTUnwrap(QueueTrackMetadata(accessibilityValue: "Title\r\nArtist\u{00A0}—\u{00A0}Album\r\n"))
        XCTAssertEqual(metadata.artist, "Artist")
        XCTAssertEqual(metadata.album, "Album")
    }

    func testFlattenedExtraOrAmbiguousLinesAreRejected() {
        let invalid = [
            "Title Artist — Album", "Title\nArtist", "Title\nArtist\nAlbum",
            "Title\n\nArtist — Album", "Title\nArtist — Album\nAnother line",
            "Title\nArtist — Album — Deluxe", "Title\nBand — Name — Album",
            "Title\nArtist—Album", "Title\nArtist – Album", "Title\nArtist - Album",
            "Title\nArtist — ", "Title\n — Album", "\nArtist — Album",
            "Title\n\u{FFFC} Artist — Album", "Title\nArtist — Al\u{0}bum"
        ]
        for value in invalid { XCTAssertNil(QueueTrackMetadata(accessibilityValue: value), value) }
    }

    func testExplicitFieldsAllowAnUnknownAlbumButNeverGuessIt() throws {
        let metadata = try XCTUnwrap(QueueTrackMetadata(title: "Title", artist: "Artist — Name", album: ""))
        XCTAssertEqual(metadata.artist, "Artist — Name")
        XCTAssertEqual(metadata.trackSnapshot.album, "")
        XCTAssertNil(QueueTrackMetadata(title: "Title\nArtist", artist: "Artist", album: "Album"))
        XCTAssertNil(QueueTrackMetadata(title: "", artist: "Artist", album: "Album"))
        XCTAssertNil(QueueTrackMetadata(title: "Title", artist: " \t ", album: "Album"))
    }

    func testArtistAndSongRulesRemainExact() throws {
        let metadata = try XCTUnwrap(QueueTrackMetadata(accessibilityValue: "Song\nMaÿ — Album"))
        let artistRule = BanRule(kind: .artist, name: "Maÿ")
        let songRule = BanRule(kind: .track, name: "Song", artist: "Maÿ")
        XCTAssertEqual(metadata.matchingRule(in: [artistRule]), artistRule)
        XCTAssertEqual(metadata.matchingRule(in: [songRule]), songRule)
        XCTAssertNil(metadata.matchingRule(in: [BanRule(kind: .artist, name: "May")]))
        XCTAssertNil(metadata.matchingRule(in: [BanRule(kind: .artist, name: "Ma")]))
        XCTAssertNil(metadata.matchingRule(in: [BanRule(kind: .track, name: "Song", artist: "Other")]))
    }

    func testQueueArtistRulesAutomaticallyIncludeRecognizedCollaborations() throws {
        let metadata = try XCTUnwrap(QueueTrackMetadata(accessibilityValue: "Song (feat. Maÿ)\nLead — Album"))
        let rule = BanRule(kind: .artist, name: "Maÿ")
        XCTAssertEqual(metadata.matchingRule(in: [rule]), rule)
        let jointCredit = try XCTUnwrap(QueueTrackMetadata(accessibilityValue: "Song\nLead & Maÿ — Album"))
        XCTAssertEqual(jointCredit.matchingRule(in: [rule]), rule)
        XCTAssertNil(metadata.matchingRule(in: [BanRule(kind: .track, name: "Song (feat. Maÿ)", artist: "Maÿ")]))
        XCTAssertNil(metadata.matchingRule(in: [BanRule(kind: .album, name: "Album", artist: "Maÿ")]))
        XCTAssertNil(jointCredit.matchingRule(in: [BanRule(kind: .track, name: "Song", artist: "Maÿ")]))
        XCTAssertNil(jointCredit.matchingRule(in: [BanRule(kind: .album, name: "Album", artist: "Maÿ")]))
    }

    func testAlbumRequiresExactArtistAndAlbumWithoutInferredAlbumArtist() throws {
        let metadata = try XCTUnwrap(QueueTrackMetadata(accessibilityValue: "Song\nLead — Album"))
        let rule = BanRule(kind: .album, name: "Album", artist: "Lead")
        XCTAssertEqual(metadata.matchingRule(in: [rule]), rule)
        XCTAssertNil(metadata.matchingRule(in: [BanRule(kind: .album, name: "Album", artist: "Other")]))
        XCTAssertNil(metadata.matchingRule(in: [BanRule(kind: .album, name: "Album Deluxe", artist: "Lead")]))
        let guest = try XCTUnwrap(QueueTrackMetadata(accessibilityValue: "Song\nGuest — Album"))
        XCTAssertNil(guest.matchingRule(in: [rule]))
        let missingAlbum = try XCTUnwrap(QueueTrackMetadata(title: "Song", artist: "Lead", album: ""))
        XCTAssertNil(missingAlbum.matchingRule(in: [rule]))
    }

    func testCompilationAlbumsAreNotPreemptivelyRemovedFromGenericCredits() throws {
        for credit in ["Various Artists", "Multi-interprètes", "Artistes variés"] {
            let metadata = try XCTUnwrap(QueueTrackMetadata(title: "Song", artist: credit, album: "Compilation"))
            XCTAssertNil(metadata.matchingRule(in: [BanRule(kind: .album, name: "Compilation", artist: credit)]))
        }
        let metadata = try XCTUnwrap(QueueTrackMetadata(title: "Song", artist: "Singer", album: "Compilation"))
        XCTAssertNil(metadata.matchingRule(in: [BanRule(kind: .album, name: "Compilation", artist: "Various Artists")]))
    }

    func testSyntheticIdentityIsStableAndUnambiguous() throws {
        let first = try XCTUnwrap(QueueTrackMetadata(title: "Song", artist: "Maÿ", album: "Album"))
        let equivalent = try XCTUnwrap(QueueTrackMetadata(title: " SONG ", artist: "MAY\u{308}", album: " ALBUM "))
        let otherAlbum = try XCTUnwrap(QueueTrackMetadata(title: "Song", artist: "Maÿ", album: "Other"))
        XCTAssertEqual(first.trackSnapshot.id, equivalent.trackSnapshot.id)
        XCTAssertNotEqual(first.trackSnapshot.id, otherAlbum.trackSnapshot.id)
    }
}

final class QueueSectionParserTests: XCTestCase {
    func testContinuationRecognizesOnlyTheVerifiedExactLocalizedHeaders() {
        for value in ["Poursuivre la lecture", " poursuivre  la LECTURE ",
                      "\u{FFFC} Poursuivre la lecture", "Poursuivre la lecture\nDescription",
                      "Continue Playing", " continue playing ", "Continue Playing\nDescription"] {
            XCTAssertEqual(QueueSectionParser.futureSection(value), .continuation, value)
            XCTAssertFalse(QueueSectionParser.isAutoplayHeader(value), value)
        }
        for value in ["Poursuivre la lecture de cet album", "Poursuivre la lecture (12)",
                      "Continue Playing (12)", "Continue playback", "Playing Next", "Up Next",
                      "Something\nPoursuivre la lecture"] {
            XCTAssertNil(QueueSectionParser.futureSection(value), value)
        }
    }

    func testExactLocalizedHeadersMayContainFollowingDescriptionLines() {
        for value in ["Lecture automatique", "Autoplay", "AutoPlay", " autoplay ",
                      "Lecture automatique\nDes morceaux similaires seront lus.",
                      "\u{FFFC} Lecture automatique\nDes morceaux similaires seront lus.",
                      "AutoPlay\r\nSimilar songs will play."] {
            XCTAssertTrue(QueueSectionParser.isAutoplayHeader(value), value)
            XCTAssertEqual(QueueSectionParser.futureSection(value), .autoplay, value)
        }
    }

    func testOtherOrFlattenedHeadersAreRejected() {
        for value in ["", "À suivre", "Up Next", "History", "Now Playing", "Auto Play",
                      "Lecture automatique Des morceaux similaires seront lus.",
                      "Autoplay Similar songs will play.", "Lecture automatique de cet artiste",
                      "Something\nAutoplay", "My Autoplay", "Autoplay (12)"] {
            XCTAssertFalse(QueueSectionParser.isAutoplayHeader(value), value)
        }
    }
}

final class MusicQueueSnapshotTests: XCTestCase {
    func testUpcomingTracksKeepContinuationAndAutoplaySeparateFromHistoryAndCurrent() {
        let snapshot = MusicQueueSnapshot(elements: [
            .sectionHeader("Historique"), .track("Old song\nBlocked — Album"),
            .sectionHeader("Morceau en cours"), .track("Current song\nBlocked — Album"),
            .sectionHeader("Poursuivre la lecture"),
            .track("Playlist song\nBlocked — Album"), .track("Allowed playlist song\nAllowed — Album"),
            .sectionHeader("Lecture automatique"), .track("Suggested song\nBlocked — Album"),
            .sectionHeader("Unknown section"), .track("Unverified song\nBlocked — Album")
        ])
        XCTAssertEqual(snapshot.upcomingTracks.map(\.elementIndex), [5, 6, 8])
        XCTAssertEqual(snapshot.upcomingTracks.map(\.section), [.continuation, .continuation, .autoplay])
        XCTAssertEqual(snapshot.upcomingTracks.map(\.headerIndex), [4, 4, 7])
        XCTAssertEqual(snapshot.autoplayTracks.map(\.elementIndex), [8])
        XCTAssertEqual(snapshot.matchingCandidates(in: [BanRule(kind: .artist, name: "Blocked")]).map(\.elementIndex), [5, 8])
    }

    func testUnknownHeadersCloseFutureSectionsUntilAnotherVerifiedHeader() {
        let snapshot = MusicQueueSnapshot(elements: [
            .sectionHeader("Poursuivre la lecture"), .track("One\nArtist — Album"),
            .sectionHeader("Unknown"), .track("Hidden\nArtist — Album"),
            .sectionHeader("Poursuivre la lecture"), .track("Two\nArtist — Album"),
            .sectionHeader("Now Playing"), .track("Current\nArtist — Album")
        ])
        XCTAssertEqual(snapshot.upcomingTracks.map(\.elementIndex), [1, 5])
        XCTAssertEqual(snapshot.upcomingTracks.map(\.headerIndex), [0, 4])
        XCTAssertTrue(snapshot.autoplayTracks.isEmpty)
    }

    func testTrackTitlesAndUnknownRowsCannotOpenFutureSections() {
        let snapshot = MusicQueueSnapshot(elements: [
            .track("Poursuivre la lecture\nArtist — Album"), .track("Before\nBlocked — Album"),
            .unknown("Poursuivre la lecture"), .track("Still before\nBlocked — Album"),
            .sectionHeader("Poursuivre la lecture"),
            .track("Autoplay\nBlocked — Album"), .track("Poursuivre la lecture\nBlocked — Album")
        ])
        XCTAssertEqual(snapshot.upcomingTracks.map(\.elementIndex), [5, 6])
        XCTAssertEqual(snapshot.upcomingTracks.map(\.section), [.continuation, .continuation])
        XCTAssertEqual(snapshot.upcomingTracks.map(\.headerIndex), [4, 4])
        XCTAssertTrue(snapshot.autoplayTracks.isEmpty)
    }

    func testOnlyRowsAfterVisibleAutoplayHeaderAndBeforeNextSectionAreEligible() {
        let snapshot = MusicQueueSnapshot(elements: [
            .sectionHeader("History"), .track("Old song\nBlocked — Album"),
            .sectionHeader("Now Playing"), .track("Current song\nBlocked — Album"),
            .sectionHeader("Up Next"), .track("Queued song\nBlocked — Album"),
            .sectionHeader("AutoPlay\nSimilar songs will play."),
            .track("Suggested song\nBlocked — Album"),
            .unknown("Decorative content"), .track("Another suggestion\nAllowed — Album"),
            .sectionHeader("Another section"), .track("Other song\nBlocked — Album")
        ])
        XCTAssertEqual(snapshot.autoplayTracks.map(\.elementIndex), [7, 9])
        let matches = snapshot.matchingCandidates(in: [BanRule(kind: .artist, name: "Blocked")])
        XCTAssertEqual(matches.map(\.elementIndex), [7])
        XCTAssertEqual(matches.first?.metadata.title, "Suggested song")
    }

    func testNoVisibleExactAutoplayHeaderMeansNoCandidates() {
        let absent = MusicQueueSnapshot(elements: [.track("Suggested song\nBlocked — Album")])
        let flattened = MusicQueueSnapshot(elements: [
            .sectionHeader("Lecture automatique Des morceaux similaires seront lus."),
            .track("Suggested song\nBlocked — Album")
        ])
        XCTAssertTrue(absent.autoplayTracks.isEmpty)
        XCTAssertTrue(flattened.autoplayTracks.isEmpty)
        XCTAssertTrue(absent.upcomingTracks.isEmpty)
        XCTAssertTrue(flattened.upcomingTracks.isEmpty)
    }

    func testUnparseableAndUnknownRowsCannotBecomeCandidates() throws {
        let metadata = try XCTUnwrap(QueueTrackMetadata(title: "Reliable", artist: "Artist", album: "Album"))
        let snapshot = MusicQueueSnapshot(elements: [
            .sectionHeader("Lecture automatique"),
            .track("Flat title Artist — Album"), .unknown("Song\nArtist — Album"),
            .separatedTrack(metadata)
        ])
        XCTAssertEqual(snapshot.autoplayTracks.map(\.metadata), [metadata])
        XCTAssertEqual(snapshot.autoplayTracks.first?.elementIndex, 3)
    }

    func testWholeSnapshotIdentityIsStableAndIncludesOrderAndUnparsedRows() {
        let elements: [MusicQueueSnapshot.Element] = [
            .sectionHeader("AutoPlay"), .track("One\nArtist — Album"),
            .track("Two\nArtist — Album"), .unknown("Unparsed original")
        ]
        let snapshot = MusicQueueSnapshot(elements: elements)
        XCTAssertEqual(snapshot.identity, MusicQueueSnapshot(elements: elements).identity)
        XCTAssertNotEqual(snapshot.identity, MusicQueueSnapshot(elements: [elements[0], elements[2], elements[1], elements[3]]).identity)
        XCTAssertNotEqual(snapshot.identity, MusicQueueSnapshot(elements: Array(elements.prefix(3)) + [.unknown("Changed")]).identity)
        XCTAssertNotEqual(snapshot.identity, MusicQueueSnapshot(elements: Array(elements.dropLast())).identity)
    }
}
