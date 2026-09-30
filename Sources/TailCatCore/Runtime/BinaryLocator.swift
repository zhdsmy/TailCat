import Foundation

/// Finds the tailcat executable. A GUI app launched from Finder gets a minimal PATH that lacks
/// Homebrew, so the usual install directories are searched explicitly.
public struct BinaryLocator: Sendable {
    public var customPath: @Sendable () -> String?
    public var searchDirectories: [String]
    public var environmentPATH: String?
    public var isExecutable: @Sendable (String) -> Bool

    public init(
        customPath: @escaping @Sendable () -> String? = { AppSettings().customBinaryPath },
        searchDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
        environmentPATH: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.customPath = customPath
        self.searchDirectories = searchDirectories
        self.environmentPATH = environmentPATH
        self.isExecutable = isExecutable
    }

    public func locate() -> URL? {
        var candidates: [String] = []
        if let custom = customPath(), !custom.isEmpty { candidates.append(custom) }
        let dirs = searchDirectories + (environmentPATH?.split(separator: ":").map(String.init) ?? [])
        candidates.append(contentsOf: dirs.map { ($0 as NSString).appendingPathComponent("tailcat") })

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted && isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
