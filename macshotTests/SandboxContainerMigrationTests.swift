import Foundation
import XCTest

/// `SandboxContainerMigration` recovers recordings/history left behind in a
/// sandboxed build's per-bundle-ID container after Markclip disabled the
/// sandbox (Phase 1 identity — see ROADMAP.md). These tests use isolated
/// temp directories standing in for `~/Library/Containers` and the real
/// (unsandboxed) Application Support directory, so they never touch the
/// developer machine's actual home directory.
final class SandboxContainerMigrationTests: XCTestCase {
    private var containers: URL!
    private var support: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        containers = root.appendingPathComponent("Containers")
        support = root.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: containers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containers.deletingLastPathComponent())
    }

    /// Creates `containers/<bundleID>/Data/Library/Application
    /// Support/com.sw33tlie.macshot/<fileName>` with `contents`, mirroring
    /// what a sandboxed old build would have written.
    private func makeOldContainer(bundleID: String, fileName: String = "Recordings/marker.txt",
                                  contents: String = "old data") throws {
        let dataDir = containers.appendingPathComponent(bundleID)
            .appendingPathComponent("Data/Library/Application Support")
            .appendingPathComponent(SandboxContainerMigration.dataFolderName)
        let fileURL = dataDir.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL)
    }

    private func destination(_ path: String = "") -> URL {
        support.appendingPathComponent(SandboxContainerMigration.dataFolderName).appendingPathComponent(path)
    }

    func testCopiesTheOnlyMatchingContainer() throws {
        try makeOldContainer(bundleID: "com.dixon.macshot.dev")
        SandboxContainerMigration.runIfNeeded(containersDirectory: containers, applicationSupportDirectory: support)

        let copied = destination("Recordings/marker.txt")
        XCTAssertEqual(try Data(contentsOf: copied), Data("old data".utf8))
    }

    func testNeverDeletesOrMovesTheOriginal() throws {
        try makeOldContainer(bundleID: "com.dixon.macshot.dev")
        let original = containers.appendingPathComponent("com.dixon.macshot.dev/Data/Library/Application Support")
            .appendingPathComponent(SandboxContainerMigration.dataFolderName)
            .appendingPathComponent("Recordings/marker.txt")
        SandboxContainerMigration.runIfNeeded(containersDirectory: containers, applicationSupportDirectory: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path),
                      "the old container's data must survive the migration untouched")
    }

    func testDoesNothingWhenTheDestinationAlreadyExists() throws {
        try makeOldContainer(bundleID: "com.dixon.macshot.dev")
        try FileManager.default.createDirectory(at: destination(), withIntermediateDirectories: true)
        try Data("already migrated".utf8).write(to: destination("marker.txt"))

        SandboxContainerMigration.runIfNeeded(containersDirectory: containers, applicationSupportDirectory: support)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination("Recordings/marker.txt").path),
                       "must not merge into an existing destination — an already-migrated (or fresh) install is left alone")
        XCTAssertEqual(try Data(contentsOf: destination("marker.txt")), Data("already migrated".utf8))
    }

    func testDoesNothingWithNoMatchingContainer() {
        SandboxContainerMigration.runIfNeeded(containersDirectory: containers, applicationSupportDirectory: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
    }

    func testDoesNothingWhenTwoContainersMatchRatherThanGuessing() throws {
        try makeOldContainer(bundleID: "com.dixon.macshot.dev", contents: "dev build")
        try makeOldContainer(bundleID: "com.sw33tlie.macshot.macshot", contents: "official build")

        SandboxContainerMigration.runIfNeeded(containersDirectory: containers, applicationSupportDirectory: support)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path),
                       "ambiguous — must not silently pick one and hide the other's data")
    }

    func testIgnoresContainersThatDontContainMacshotInTheirName() throws {
        // A folder that happens to live under ~/Library/Containers but isn't
        // one of ours must never be treated as a migration source.
        let unrelated = containers.appendingPathComponent("com.apple.Notes/Data/Library/Application Support")
            .appendingPathComponent(SandboxContainerMigration.dataFolderName)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("not ours".utf8).write(to: unrelated.appendingPathComponent("marker.txt"))

        SandboxContainerMigration.runIfNeeded(containersDirectory: containers, applicationSupportDirectory: support)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
    }

    func testMatchingIsCaseInsensitive() throws {
        try makeOldContainer(bundleID: "com.example.MacShot.dev")
        SandboxContainerMigration.runIfNeeded(containersDirectory: containers, applicationSupportDirectory: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination("Recordings/marker.txt").path))
    }

    func testMissingContainersDirectoryIsHandledGracefully() {
        let missing = containers.appendingPathComponent("does-not-exist")
        SandboxContainerMigration.runIfNeeded(containersDirectory: missing, applicationSupportDirectory: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
    }
}
