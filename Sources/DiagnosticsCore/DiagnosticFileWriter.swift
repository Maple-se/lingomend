import Darwin
import Foundation

protocol DiagnosticWriting: AnyObject {
    func open() throws
    func append(_ record: DiagnosticRecord) throws
    func clear() throws
    func close()
}

/// Queue-confined. Only these five filenames can ever be rotated or removed.
final class DiagnosticFileWriter: DiagnosticWriting {
    static let fileLimit = 1_048_576
    static let fileCount = 5
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let names = ["runtime.log", "runtime.1.log", "runtime.2.log", "runtime.3.log", "runtime.4.log"]
    private let directory: URL
    private var handle: FileHandle?
    private var owner: Int32 = -1
    private var size = 0
    private let encoder = JSONEncoder()
    private let fm = FileManager.default
    private var header: FileHeader?
    init(directory: URL) { self.directory = directory; encoder.outputFormatting = [.sortedKeys] }
    deinit { close() }

    func open() throws {
        try acquire()
        try prune()
        try openCurrent()
    }
    private func acquire() throws {
        guard owner < 0 else { return }
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw FileError.unsafe }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd = Darwin.open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0, fchmod(fd, 0o600) == 0 else {
            Darwin.close(fd); throw FileError.unavailable
        }
        owner = fd
    }
    private func url(_ index: Int) -> URL { directory.appendingPathComponent(Self.names[index]) }
    private func existing(_ index: Int) throws -> Bool {
        var info = stat()
        if lstat(url(index).path, &info) != 0 {
            guard errno == ENOENT else { throw FileError.unavailable }
            return false
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw FileError.unsafe }
        return true
    }
    private func prune() throws {
        for index in 0..<Self.fileCount where try existing(index) {
            let attributes = try fm.attributesOfItem(atPath: url(index).path)
            if ((attributes[.size] as? NSNumber)?.intValue ?? 0) > Self.fileLimit
                || (attributes[.modificationDate] as? Date ?? .distantPast) < Date().addingTimeInterval(-Self.retention) {
                try fm.removeItem(at: url(index))
            } else { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(index).path) }
        }
    }
    private func openCurrent() throws {
        _ = try existing(0)
        let fd = Darwin.open(url(0).path, O_CREAT | O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, fchmod(fd, 0o600) == 0 else {
            Darwin.close(fd); throw FileError.unsafe
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); size = Int(info.st_size)
        // A force-quit may leave a partial final line. Remove that fragment before appending.
        if size > 0 {
            let data = try handle!.readToEnd() ?? Data()
            if data.last != 0x0a {
                size = data.lastIndex(of: 0x0a).map { $0 + 1 } ?? 0
                guard ftruncate(fd, off_t(size)) == 0 else { throw FileError.unavailable }
            }
        }
    }
    func append(_ record: DiagnosticRecord) throws {
        if record.event.name == .sessionStarted {
            header = FileHeader(session: record.session, channel: record.channel, version: record.version, build: record.build)
        }
        var line = try encoder.encode(record); line.append(0x0a)
        guard line.count <= Self.fileLimit else { throw FileError.unsafe }
        if size + line.count > Self.fileLimit { try rotate() }
        guard let handle else { throw FileError.unavailable }
        if size == 0, record.event.name != .sessionStarted, let header {
            var metadata = try encoder.encode(header); metadata.append(0x0a)
            guard metadata.count + line.count <= Self.fileLimit else { throw FileError.unsafe }
            try handle.write(contentsOf: metadata); size += metadata.count
        }
        try handle.write(contentsOf: line); size += line.count
    }
    private func rotate() throws {
        try handle?.close(); handle = nil
        try prune()
        if try existing(4) { try fm.removeItem(at: url(4)) }
        for index in stride(from: 3, through: 0, by: -1) where try existing(index) {
            if try existing(index + 1) { try fm.removeItem(at: url(index + 1)) }
            try fm.moveItem(at: url(index), to: url(index + 1))
        }
        try openCurrent()
    }
    func clear() throws {
        try handle?.close(); handle = nil; size = 0
        // Off + never opened: clearing should not create a directory or a lock file.
        guard fm.fileExists(atPath: directory.path) else { return }
        try acquire()
        for index in 0..<Self.fileCount { _ = try existing(index) }
        for index in 0..<Self.fileCount where try existing(index) { try fm.removeItem(at: url(index)) }
    }
    func close() {
        try? handle?.close(); handle = nil
        if owner >= 0 { _ = flock(owner, LOCK_UN); Darwin.close(owner); owner = -1 }
    }
    private enum FileError: Error { case unsafe, unavailable }
    private struct FileHeader: Encodable {
        let type = "fileHeader"
        let schema = 1
        let session: UUID
        let channel: BuildChannel?
        let version: String?
        let build: Int?
    }
}
