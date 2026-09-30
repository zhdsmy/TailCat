import Foundation

/// Tracks child pids on disk so a crashed/killed app does not leave orphaned tailcat processes
/// holding the local ports.
public struct PIDTracker: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("pids.json")
    }

    public func load() -> [String: Int32] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: Int32].self, from: data) else { return [:] }
        return map
    }

    public func save(_ map: [String: Int32]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// SIGTERM every recorded pid that is still a tailcat process (guards against pid reuse).
    public func reapOrphans(isTailcat: (Int32) -> Bool = PIDTracker.looksLikeTailcat) {
        for pid in load().values where isTailcat(pid) { kill(pid, SIGTERM) }
        save([:])
    }

    public static func looksLikeTailcat(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == "tailcat"
    }
}
