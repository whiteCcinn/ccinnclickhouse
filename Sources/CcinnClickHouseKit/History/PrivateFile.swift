import Foundation

/// Writes files that hold user data (history, saved connections) so they never exist with wider
/// permissions than 0600, not even briefly: a temporary file is created with mode 0600 (`O_EXCL`) next
/// to the target, filled and synced, then renamed over it. A `.atomic` write followed by `chmod` would
/// create each new inode with the umask default (typically 0644) first.
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temporary.path]) }
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        renamed = true
    }
}
