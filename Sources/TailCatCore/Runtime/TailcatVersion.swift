import Foundation

/// `tailcat version` output such as `v0.7.0` (pre-release suffixes are ignored for ordering).
public struct TailcatVersion: Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var raw: String

    public init(_ major: Int, _ minor: Int, _ patch: Int, raw: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.raw = raw ?? "v\(major).\(minor).\(patch)"
    }

    public static func parse(_ text: String) -> TailcatVersion? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        var core = token.hasPrefix("v") ? String(token.dropFirst()) : token
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = String(core[..<cut]) }
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
        return TailcatVersion(parts[0]!, parts[1]!, parts.count > 2 ? parts[2]! : 0, raw: token)
    }

    public static func < (a: TailcatVersion, b: TailcatVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public static func == (a: TailcatVersion, b: TailcatVersion) -> Bool {
        (a.major, a.minor, a.patch) == (b.major, b.minor, b.patch)
    }

    public var description: String { raw }
}

/// Features that depend on the installed tailcat.
public struct TailcatCapabilities: Equatable, Sendable {
    /// `tailcat perf` and the `perf` service landed after v0.7.0.
    public var perf: Bool

    /// serve's `port:target` mappings (`8080:80`) landed in the same post-v0.7.0 batch, just before
    /// perf. Their help text gives nothing stable to probe, so they follow perf's detection.
    public var serveMappings: Bool { perf }

    public init(perf: Bool = false) {
        self.perf = perf
    }

    public static let perfIntroducedAfter = TailcatVersion(0, 7, 0)

    public static func from(version: TailcatVersion?) -> TailcatCapabilities {
        TailcatCapabilities(perf: version.map { $0 > perfIntroducedAfter } ?? false)
    }
}
