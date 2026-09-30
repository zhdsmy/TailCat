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
