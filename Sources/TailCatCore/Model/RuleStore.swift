import Foundation

public enum RuleStoreError: Error, LocalizedError {
    /// The file could not be decoded; it was moved aside to `backup` so it is not overwritten.
    case corrupt(backup: URL)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let backup):
            return "数据文件已损坏，已备份到 \(backup.path)，当前从空列表开始。"
        }
    }
}

/// Reads and writes files that hold credentials (tc addresses): the file is 0600 and the
/// directory 0700; writes go through a 0600 temp file and an atomic rename.
public enum SecureFile {
    public static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // createDirectory leaves an existing directory's mode alone.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // rename(2) keeps the temp file's 0600; replaceItemAt would carry over the old file's mode.
        guard rename(tmp.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? fm.removeItem(at: tmp)
            throw POSIXError(code)
        }
    }

    /// Moves an undecodable file aside so the next save does not destroy it.
    public static func quarantine(_ url: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(base).corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
        return backup
    }
}

/// Persists tunnel rules as `{"version": N, "rules": [...]}`.
public final class RuleStore: @unchecked Sendable {
    private struct FileFormat: Codable {
        var version: Int
        var rules: [TunnelRule]
    }

    /// v1: forward-only rules. v2: `kind`, server/socks options, and `remoteID`.
    public static let currentVersion = 2

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("rules.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailCat", isDirectory: true)
    }

    public func load() throws -> [TunnelRule] {
        guard let data = SecureFile.read(fileURL) else { return [] }
        do {
            return try JSONDecoder().decode(FileFormat.self, from: data).rules
        } catch {
            throw RuleStoreError.corrupt(backup: SecureFile.quarantine(fileURL))
        }
    }

    public func save(_ rules: [TunnelRule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.write(encoder.encode(FileFormat(version: Self.currentVersion, rules: rules)), to: fileURL)
    }
}

/// Persists a list as `{"version": 1, "items": [...]}` with the same protections as RuleStore.
public final class ListStore<Item: Codable>: @unchecked Sendable {
    private struct FileFormat: Codable {
        var version: Int
        var items: [Item]
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [Item] {
        guard let data = SecureFile.read(fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(FileFormat.self, from: data).items
        } catch {
            throw RuleStoreError.corrupt(backup: SecureFile.quarantine(fileURL))
        }
    }

    public func save(_ items: [Item]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try SecureFile.write(encoder.encode(FileFormat(version: 1, items: items)), to: fileURL)
    }
}
