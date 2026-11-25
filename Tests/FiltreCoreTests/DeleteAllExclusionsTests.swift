import Foundation
import XCTest
@testable import FiltreCore

final class DeleteAllExclusionsTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicFilterDeleteAllTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("exclusions.json")
    }

    private func populate(_ store: BanStore) throws {
        try store.addArtist("Example artist")
        try store.addAlbum(name: "Example album", artist: "Example band")
        try store.addTrack(.init(id: "example-song", title: "Example song",
                                 artist: "Example singer", album: "Example release", isPlaying: false))
    }

    func testClearsEveryKindPersistsEmptyListAndAllowsNewExclusions() throws {
        let store = try BanStore(fileURL: temporaryURL())
        try populate(store)
        XCTAssertEqual(Set(store.rules.map(\.kind.rawValue)), ["artist", "album", "track"])

        try store.removeAll()

        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(try BanStore(fileURL: store.fileURL).rules.isEmpty)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 1)
        XCTAssertEqual((document["rules"] as? [Any])?.count, 0)

        let added = try store.addArtist("Another artist")
        XCTAssertEqual(try BanStore(fileURL: store.fileURL).rules, [added])
    }

    func testEmptyStoreDoesNotCreateAFileOrParentFolder() throws {
        let url = try temporaryURL().deletingLastPathComponent()
            .appendingPathComponent("not-created/exclusions.json")
        let store = try BanStore(fileURL: url)

        try store.removeAll()

        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testAlreadyEmptyFileIsNotRewritten() throws {
        let url = try temporaryURL()
        let emptyDocument = Data("{\"rules\":[],\"version\":1}\n".utf8)
        try emptyDocument.write(to: url)
        let fixedDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let store = try BanStore(fileURL: url)

        try store.removeAll()

        XCTAssertEqual(try Data(contentsOf: url), emptyDocument)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
                       beforeAttributes[.modificationDate] as? Date)
    }

    func testFailedWritePreservesTheListInMemoryAndOnDisk() throws {
        let url = try temporaryURL()
        let store = try BanStore(fileURL: url)
        try populate(store)
        let originalRules = store.rules
        let originalData = try Data(contentsOf: url)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        guard !FileManager.default.isWritableFile(atPath: folder.path) else {
            throw XCTSkip("This test needs a process that respects private-directory write permissions.")
        }

        XCTAssertThrowsError(try store.removeAll())

        XCTAssertEqual(store.rules, originalRules)
        XCTAssertEqual(try Data(contentsOf: url), originalData)
        XCTAssertEqual(try BanStore(fileURL: url).rules, originalRules)
    }

    func testExportedBackupRestoresTheListAfterDeletingAll() throws {
        let store = try BanStore(fileURL: temporaryURL())
        try populate(store)
        let original = store.rules
        let backup = try store.exportedData()
        try store.removeAll()
        let emptyStore = try BanStore(fileURL: store.fileURL)

        let result = try emptyStore.importData(backup)

        XCTAssertEqual(result.addedCount, 3)
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertEqual(emptyStore.rules, original)
        XCTAssertEqual(try BanStore(fileURL: store.fileURL).rules, original)
    }
}
