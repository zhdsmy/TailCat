import Foundation

/// Tracks child processes on disk so a crashed/killed app does not leave orphaned tailcat processes
/// holding the local ports.
public struct PIDTracker: Sendable {
    /// Executable and start time tell our child apart from an unrelated process that later got
    /// the same pid, whatever the configured tailcat binary is called.
    public struct Identity: Codable, Equatable, Sendable {
        public var pid: Int32
        public var path: String
        /// Microseconds since the epoch.
        public var started: UInt64

        public init(pid: Int32, path: String, started: UInt64) {
            self.pid = pid
            self.path = path
            self.started = started
        }

        /// nil when the process is gone.
        public static func of(_ pid: Int32) -> Identity? {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return Identity(pid: pid, path: String(cString: buffer),
                            started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
        }
    }

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("pids.json")
    }

    public func load() -> [String: Identity] {
        // 0.1.0 stored bare pids, which cannot tell our child from a tailcat the user started after
        // the pid was reused; they fail to decode and are dropped rather than signalled.
        guard let data = try? SecureFile.read(fileURL),
              let map = try? JSONDecoder().decode([String: Identity].self, from: data) else { return [:] }
        return map
    }

    public func save(_ map: [String: Identity]) {
        if let data = try? JSONEncoder().encode(map) { try? SecureFile.write(data, to: fileURL) }
    }

    /// SIGTERM every recorded process that is still the one we started.
    public func reapOrphans(identify: (Int32) -> Identity? = Identity.of,
                            signal: (Int32) -> Void = { kill($0, SIGTERM) }) {
        for recorded in load().values where identify(recorded.pid) == recorded { signal(recorded.pid) }
        save([:])
    }
}
