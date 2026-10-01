import Foundation

public enum RuleStoreError: Error, LocalizedError {
    /// The file could not be decoded; it was moved aside to `backup` so it is not overwritten.
    case corrupt(backup: URL)
    case unsupportedVersion(Int)
    case writeBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let backup):
            return "数据文件已损坏，已备份到 \(backup.path)，当前从空列表开始。"
        case .unsupportedVersion(let version):
            return "数据文件版本 \(version) 不受支持，已保留原文件，请使用兼容的 TailCat 版本。"
        case .writeBlocked(let reason):
            return "配置未能载入，已阻止覆盖：\(reason)。请修复文件后重新启动 TailCat。"
        }
    }
}

/// Reads and writes files that hold credentials (tc addresses): the file is 0600 and the
/// directory 0700; writes go through a 0600 temp file and an atomic rename.
public enum SecureFile {
    public static func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) } catch {
            let code = (error as? CocoaError)?.code
            if code == .fileReadNoSuchFile || code == .fileNoSuchFile { return nil }
            throw error
        }
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
    public static func quarantine(_ url: URL) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(base).corrupt-\(stamp)-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: url, to: backup)
        return backup
    }

    private struct Version: Decodable { var version: Int }

    /// Check the envelope before decoding items: future item schemas must not be quarantined
    /// as corrupt and replaced by an empty list when an older app opens them.
    static func decode<T: Decodable>(_ type: T.Type, at url: URL, versions: ClosedRange<Int>,
                                     decoder: JSONDecoder = JSONDecoder()) throws -> T? {
        guard let data = try read(url) else { return nil }
        do {
            let version = try decoder.decode(Version.self, from: data).version
            guard versions.contains(version) else { throw RuleStoreError.unsupportedVersion(version) }
            return try decoder.decode(type, from: data)
        } catch is DecodingError {
            throw RuleStoreError.corrupt(backup: try quarantine(url))
        }
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
    private var loadFailure: String?
    public var fileURL: URL { directory.appendingPathComponent("rules.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailCat", isDirectory: true)
    }

    public func load() throws -> [TunnelRule] {
        do {
            let rules = try SecureFile.decode(FileFormat.self, at: fileURL, versions: 1...Self.currentVersion)?.rules ?? []
            loadFailure = nil
            return rules
        } catch RuleStoreError.corrupt(let backup) {
            loadFailure = nil // A verified backup makes starting over safe.
            throw RuleStoreError.corrupt(backup: backup)
        } catch {
            loadFailure = error.localizedDescription
            throw error
        }
    }

    public func save(_ rules: [TunnelRule]) throws {
        if let loadFailure { throw RuleStoreError.writeBlocked(loadFailure) }
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
    private var loadFailure: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [Item] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let items = try SecureFile.decode(FileFormat.self, at: fileURL, versions: 1...1, decoder: decoder)?.items ?? []
            loadFailure = nil
            return items
        } catch RuleStoreError.corrupt(let backup) {
            loadFailure = nil
            throw RuleStoreError.corrupt(backup: backup)
        } catch {
            loadFailure = error.localizedDescription
            throw error
        }
    }

    public func save(_ items: [Item]) throws {
        if let loadFailure { throw RuleStoreError.writeBlocked(loadFailure) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try SecureFile.write(encoder.encode(FileFormat(version: 1, items: items)), to: fileURL)
    }
}
