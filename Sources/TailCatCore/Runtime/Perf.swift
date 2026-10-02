import Foundation

/// Options for `tailcat perf` (flags from cmd/tailcat/perf.go).
public struct PerfOptions: Equatable, Sendable {
    public enum Proto: String, CaseIterable, Sendable { case tcp, udp }
    public enum Direction: String, CaseIterable, Sendable {
        case upload, download, both

        public var label: String {
            switch self {
            case .upload: return L10n.tr("上传（本机 → 远端）")
            case .download: return L10n.tr("下载（远端 → 本机）")
            case .both: return L10n.tr("双向")
            }
        }
    }

    public var proto: Proto = .tcp
    public var direction: Direction = .upload
    public var parallel = 1
    public var seconds = 10
    /// Per-stream byte budget with optional K/M/G suffix; empty = send for `seconds`.
    public var bytes = ""
    /// Per-stream bitrate with optional K/M/G suffix; empty = tailcat's default.
    public var bitrate = ""
    public var viaDERP = false
    public var timeoutSeconds = 10

    public init() {}

    public var isValid: Bool {
        (1...128).contains(parallel) && (1...3600).contains(seconds) && (1...600).contains(timeoutSeconds)
            && Self.isSI(bytes) && Self.isSI(bitrate)
    }

    /// Flags placed after the `perf` subcommand.
    public func arguments() -> [String] {
        var args: [String] = []
        if proto == .udp { args.append("--udp") }
        switch direction {
        case .upload: break
        case .download: args.append("--reverse")
        case .both: args.append("--bidir")
        }
        if parallel != 1 { args.append("--parallel=\(parallel)") }
        if !bytes.isEmpty { args.append("--bytes=\(bytes)") } else { args.append("--time=\(seconds)s") }
        if !bitrate.isEmpty { args.append("--bitrate=\(bitrate)") }
        if viaDERP { args.append("--via-derp") }
        args.append("--timeout=\(timeoutSeconds)s")
        return args
    }

    /// Upper bound for the whole run, used as a hard kill timeout.
    public var hardTimeout: TimeInterval {
        TimeInterval(timeoutSeconds + (bytes.isEmpty ? seconds : 600) + 30)
    }

    static func isSI(_ s: String) -> Bool {
        guard !s.isEmpty else { return true }
        var body = Substring(s)
        if let last = body.last, "KMGkmg".contains(last) { body = body.dropLast() }
        return !body.isEmpty && Double(body) != nil && !body.hasPrefix("-")
    }
}

/// `tailcat --json perf` output: `{"path":…, "pathAfter":…, "params":…, "clientSent":…, …}`.
/// Durations are Go `time.Duration` nanoseconds.
public struct PerfReport: Decodable, Equatable, Sendable {
    public struct PathInfo: Decodable, Equatable, Sendable {
        public var direct: Bool
        public var endpoint: String?
        public var derpRegion: String?
        public var rtt: Int64

        public var label: String {
            let rttMS = String(format: "%.1fms", Double(rtt) / 1e6)
            return direct
                ? L10n.tr("直连 %@，rtt %@", endpoint ?? "", rttMS)
                : L10n.tr("中继 DERP(%@)，rtt %@", derpRegion ?? "?", rttMS)
        }
    }

    public struct Params: Decodable, Equatable, Sendable {
        public var proto: String
        public var dir: String
        public var duration: Int64?
        public var bytes: Int64?
        public var streams: Int
        public var length: Int
        public var bitrate: Int64?
        public var interval: Int64?
    }

    public struct Interval: Decodable, Equatable, Sendable {
        public var bytes: Int64
        public var datagrams: Int64?
    }

    public struct Stats: Decodable, Equatable, Sendable {
        public var bytes: Int64
        public var datagrams: Int64?
        public var duration: Int64
        public var intervals: [Interval]?
        public var reordered: Int64?
        public var jitter: Int64?

        /// Bits per second over the stats' own duration.
        public var bitsPerSecond: Double {
            duration > 0 ? Double(bytes) * 8 / (Double(duration) / 1e9) : 0
        }
    }

    public struct RTT: Decodable, Equatable, Sendable {
        public var min: Int64
        public var avg: Int64
        public var max: Int64
        public var count: Int
    }

    public var path: PathInfo
    public var pathAfter: PathInfo?
    public var params: Params
    public var clientSent: Stats?
    public var serverReceived: Stats?
    public var serverSent: Stats?
    public var clientReceived: Stats?
    public var rtt: RTT?

    public static func decode(_ json: String) -> PerfReport? {
        guard let start = json.firstIndex(of: "{"),
              let data = String(json[start...]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PerfReport.self, from: data)
    }

    public struct Sample: Identifiable, Equatable, Sendable {
        public var series: String
        public var second: Double
        public var mbps: Double
        public var id: String { "\(series)-\(second)" }
    }

    /// Per-interval throughput from the stats the client recorded (servers' stats carry no intervals).
    public var samples: [Sample] {
        let step = Double(params.interval ?? 1_000_000_000) / 1e9
        guard step > 0 else { return [] }
        var out: [Sample] = []
        for (name, stats) in [(L10n.tr("发送"), clientSent), (L10n.tr("接收"), clientReceived)] {
            guard let intervals = stats?.intervals else { continue }
            for (i, iv) in intervals.enumerated() {
                out.append(Sample(series: name, second: Double(i + 1) * step,
                                  mbps: Double(iv.bytes) * 8 / step / 1e6))
            }
        }
        return out
    }

    public var summaryLines: [String] {
        var lines = [L10n.tr("路径：%@", path.label)]
        if let after = pathAfter, after.direct != path.direct { lines.append(L10n.tr("测试后路径：%@", after.label)) }
        func line(_ label: String, _ s: Stats?) {
            guard let s else { return }
            lines.append(L10n.tr("%@ %.2f MB，%.1f Mbit/s", label, Double(s.bytes) / 1e6, s.bitsPerSecond / 1e6))
        }
        line(L10n.tr("本机发送"), clientSent)
        line(L10n.tr("远端接收"), serverReceived)
        line(L10n.tr("远端发送"), serverSent)
        line(L10n.tr("本机接收"), clientReceived)
        if params.proto == "udp" {
            for (sent, recv, label) in [(clientSent, serverReceived, L10n.tr("上行")), (serverSent, clientReceived, L10n.tr("下行"))] {
                guard let sd = sent?.datagrams, let rd = recv?.datagrams, sd > 0 else { continue }
                let loss = Double(max(0, sd - rd)) / Double(sd) * 100
                let jitter = recv?.jitter
                let reordered = recv?.reordered.flatMap { $0 > 0 ? String($0) : nil }
                let text: String
                switch (jitter, reordered) {
                case (let jitter?, let reordered?):
                    text = L10n.tr("%@丢包 %.2f%%，抖动 %.2fms，乱序 %@", label, loss, Double(jitter) / 1e6, reordered)
                case (let jitter?, nil):
                    text = L10n.tr("%@丢包 %.2f%%，抖动 %.2fms", label, loss, Double(jitter) / 1e6)
                case (nil, let reordered?):
                    text = L10n.tr("%@丢包 %.2f%%，乱序 %@", label, loss, reordered)
                case (nil, nil):
                    text = L10n.tr("%@丢包 %.2f%%", label, loss)
                }
                lines.append(text)
            }
        }
        if let rtt {
            lines.append(L10n.tr("负载下 RTT min %.1fms avg %.1fms max %.1fms（%d 次）",
                                 Double(rtt.min) / 1e6, Double(rtt.avg) / 1e6, Double(rtt.max) / 1e6, rtt.count))
        }
        return lines
    }
}
