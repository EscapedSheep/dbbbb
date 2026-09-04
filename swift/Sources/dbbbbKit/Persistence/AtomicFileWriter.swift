import Foundation

/// Shared atomic JSON write for the persistence stores: temp file + rename,
/// directory 0700, file 0600 (mirrors the Electron vault's file modes).
public enum AtomicFileWriter {
    /// The temp file is created 0600 up front via open(2) (never via umask or
    /// a post-hoc chmod) and renamed over the target, so the bytes are never
    /// readable by other users at any point. `securingDirectory` also tightens
    /// a pre-existing target directory to 0700 — the persistence stores opt in;
    /// exports to user-chosen locations must not rewrite directory permissions.
    public static func write(_ data: Data, to fileURL: URL, securingDirectory: Bool = false) throws {
        let directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if securingDirectory {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let temporaryURL = directory
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
