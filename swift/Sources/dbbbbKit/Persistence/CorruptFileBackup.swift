import Foundation

/// Quarantine for unreadable persistence files. A corrupt file is renamed to
/// `<name>.corrupt-<timestamp>` next to itself before the store is allowed to
/// rewrite the original path, so user data is never silently destroyed.
/// (Files with an explicit foreign schema version are never sent here.)
enum CorruptFileBackup {
    /// Moves `fileURL` aside and returns true; false when the backup could not
    /// be created, in which case the caller must leave the file untouched.
    static func backup(_ fileURL: URL, now: Date = Date()) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: now)
        let backupURL = fileURL.appendingPathExtension("corrupt-\(timestamp)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            return true
        } catch {
            // Same-second collision with an earlier backup: retry on a unique name.
            let uniqueURL = fileURL.appendingPathExtension("corrupt-\(timestamp)-\(UUID().uuidString)")
            return (try? FileManager.default.moveItem(at: fileURL, to: uniqueURL)) != nil
        }
    }
}
