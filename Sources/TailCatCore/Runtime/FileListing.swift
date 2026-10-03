import Foundation

/// One line of `tailcat ls -l`: `<mode> <size:%12d> <Jan _2 15:04 | Jan _2 2006> <name>[/]`.
public struct RemoteFileEntry: Equatable, Sendable, Identifiable {
    public var mode: String
    public var size: Int64
    public var modified: String
    public var name: String
    public var isDirectory: Bool

    public var id: String { name }

    public init(mode: String, size: Int64, modified: String, name: String, isDirectory: Bool) {
        self.mode = mode
        self.size = size
        self.modified = modified
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Directory results belong to one file endpoint, even when the saved remote keeps its ID.
public struct FileBrowserState {
    public var path: String
    public private(set) var entries: [RemoteFileEntry]?
    public private(set) var loading: Bool
    public private(set) var error: String?
    private var remote: Remote
    private var requestID: UUID?

    public init(remote: Remote, path: String = ".", entries: [RemoteFileEntry]? = nil,
                loading: Bool = false, error: String? = nil) {
        self.remote = remote
        self.path = path
        self.entries = entries
        self.loading = loading
        self.error = error
    }

    @discardableResult
    public mutating func updateRemote(_ remote: Remote) -> Bool {
        let changed = self.remote.id != remote.id || self.remote.identity != remote.identity
            || self.remote.filePort != remote.filePort
        self.remote = remote
        guard changed else { return false }
        cancelListing()
        path = "."
        entries = nil
        error = nil
        return true
    }

    public mutating func beginListing() -> UUID? {
        // tailcat ls has no port option; every navigation path must honor this limitation.
        guard remote.filePort == 22 else { return nil }
        let id = UUID()
        requestID = id
        loading = true
        error = nil
        return id
    }

    public mutating func finishListing(_ result: Result<[RemoteFileEntry], CLIError>, path: String, requestID: UUID) {
        // Cancellation alone cannot reject a result that already finished before the endpoint changed.
        guard self.requestID == requestID else { return }
        self.requestID = nil
        loading = false
        switch result {
        case .success(let list):
            self.path = path
            entries = list.sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
        case .failure(let error):
            self.error = L10n.tr("列出失败：%@", error.message)
        }
    }

    public mutating func cancelListing() {
        requestID = nil
        loading = false
    }
}

public enum FileListing {
    // The name is everything after the single space following the date, so names with spaces survive.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\S+)\s+(\d+)\s+([A-Z][a-z]{2}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})) (.+)$"#)

    public static func parse(_ output: String) -> [RemoteFileEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    public static func parseLine(_ line: String) -> RemoteFileEntry? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = pattern.firstMatch(in: line, range: range), m.numberOfRanges == 5,
              let modeR = Range(m.range(at: 1), in: line),
              let sizeR = Range(m.range(at: 2), in: line),
              let dateR = Range(m.range(at: 3), in: line),
              let nameR = Range(m.range(at: 4), in: line),
              let size = Int64(line[sizeR]) else { return nil }
        var name = String(line[nameR])
        let mode = String(line[modeR])
        let isDir = name.hasSuffix("/") || mode.hasPrefix("d")
        if name.hasSuffix("/") { name.removeLast() }
        let date = line[dateR].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return RemoteFileEntry(mode: mode, size: size, modified: date, name: name, isDirectory: isDir)
    }

    /// Joins a server-relative directory and a child name; "." is the served root.
    public static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty || directory == "." ? name : directory + "/" + name
    }

    public static func parent(of directory: String) -> String {
        guard let slash = directory.lastIndex(of: "/") else { return "." }
        return String(directory[..<slash])
    }
}
