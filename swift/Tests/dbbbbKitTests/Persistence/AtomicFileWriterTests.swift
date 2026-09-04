import Foundation
import XCTest
@testable import dbbbbKit

/// Atomic writes: 0600 from creation, 0700 directory tightening, no temp litter.
final class AtomicFileWriterTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-atomic-writer-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var fileURL: URL { directory.appendingPathComponent("data.json") }

    private func posixPermissions(at url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testWrittenFileIs0600AndRoundTrips() throws {
        let data = Data(#"{"a":1}"#.utf8)
        try AtomicFileWriter.write(data, to: fileURL, securingDirectory: true)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        XCTAssertEqual(try posixPermissions(at: fileURL), 0o600)
        XCTAssertEqual(try posixPermissions(at: directory), 0o700)
    }

    func testOverwriteOfWorldReadableFileEndsAt0600() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: Data("old".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        try AtomicFileWriter.write(Data("new".utf8), to: fileURL)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "new")
        XCTAssertEqual(try posixPermissions(at: fileURL), 0o600)
    }

    func testNoTemporaryFilesRemain() throws {
        try AtomicFileWriter.write(Data("one".utf8), to: fileURL)
        try AtomicFileWriter.write(Data("two".utf8), to: fileURL)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["data.json"])
    }

    func testSecuringDirectoryTightensPreExistingDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        try AtomicFileWriter.write(Data("x".utf8), to: fileURL, securingDirectory: true)
        XCTAssertEqual(try posixPermissions(at: directory), 0o700)
    }

    /// Exports write to user-chosen locations (e.g. the Desktop): the default
    /// must never rewrite the destination directory's permissions.
    func testDefaultLeavesPreExistingDirectoryPermissionsAlone() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        try AtomicFileWriter.write(Data("x".utf8), to: fileURL)
        XCTAssertEqual(try posixPermissions(at: directory), 0o755)
    }
}
