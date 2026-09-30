import Foundation

/// One successful `tailcat ping` reply: `pong in 1.2ms via 203.0.113.7:41641`
/// or `pong in 42.1ms via DERP(sfo)`.
public struct PingResult: Equatable, Sendable {
    public enum Path: Equatable, Sendable {
        case direct(endpoint: String)
        case derp(region: String)
    }

    public var latency: TimeInterval
    public var path: Path

    public init(latency: TimeInterval, path: Path) {
        self.latency = latency
        self.path = path
    }

    public var isDirect: Bool {
        if case .direct = path { return true }
        return false
    }

    /// Short Chinese label for the menu / detail header, e.g. "直连 1.2ms" or "中继 sfo 42ms".
    public var shortLabel: String {
        let ms = latency * 1000
        let latencyText: String
        if ms < 1 {
            latencyText = String(format: "%.0fµs", latency * 1_000_000)
        } else if ms < 10 {
            latencyText = String(format: "%.1fms", ms)
        } else {
            latencyText = String(format: "%.0fms", ms)
        }
        switch path {
        case .direct:
            return "直连 \(latencyText)"
        case .derp(let region):
            // tailcat reports some relays by numeric region ID, which tells a reader nothing.
            return region.allSatisfy(\.isNumber) ? "中继 \(latencyText)" : "中继 \(region) \(latencyText)"
        }
    }

    /// `shortLabel` plus the direct endpoint or relay, for logs.
    public var detailLabel: String {
        switch path {
        case .direct(let endpoint): return "\(shortLabel) (\(endpoint))"
        case .derp(let region): return "\(shortLabel) DERP(\(region))"
        }
    }

    public static func parse(_ line: String) -> PingResult? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // pong in <duration> via <path>
        guard trimmed.hasPrefix("pong in "),
              let viaRange = trimmed.range(of: " via ") else { return nil }
        let durationText = String(trimmed["pong in ".endIndex..<viaRange.lowerBound])
        let via = String(trimmed[viaRange.upperBound...])
        guard let latency = parseGoDuration(durationText) else { return nil }

        if via.hasPrefix("DERP("), via.hasSuffix(")"), via.count > 6 {
            let region = String(via.dropFirst(5).dropLast())
            guard !region.isEmpty else { return nil }
            return PingResult(latency: latency, path: .derp(region: region))
        }
        guard !via.isEmpty else { return nil }
        return PingResult(latency: latency, path: .direct(endpoint: via))
    }

    /// Parses Go's default duration formatting: `500µs`, `1.2ms`, `42.1ms`, `1.5s`.
    public static func parseGoDuration(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let units: [(String, TimeInterval)] = [
            ("µs", 1e-6), ("μs", 1e-6), ("us", 1e-6),
            ("ms", 1e-3),
            ("s", 1),
            ("m", 60),
            ("h", 3600),
        ]
        for (suffix, factor) in units {
            guard s.hasSuffix(suffix) else { continue }
            let number = String(s.dropLast(suffix.count))
            guard let value = Double(number), value >= 0 else { return nil }
            return value * factor
        }
        return nil
    }
}
