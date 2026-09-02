import Foundation

/// Shared atomic JSON write for the persistence stores: temp file + rename,
/// directory 0700, file 0600 (mirrors the Electron vault's file modes).
public enum AtomicFileWriter {
    public static func write(_ data: Data, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
