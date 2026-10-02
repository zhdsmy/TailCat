import Foundation

public struct ListenerInfo: Hashable, Sendable {
    public var host: String
    public var port: Int
    /// The remote side as tailcat reports it, e.g. `localhost:8080`, `8080` or `192.168.1.10:3306`.
    public var target: String

    public var hostPort: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Remote side for the UI: a port on the server itself (tailcat prints it as `localhost:<port>`),
    /// or another host reached through the server.
    public var targetLabel: String {
        guard let cut = target.lastIndex(of: ":") else { return L10n.tr("远端 %@", target) }
        let host = target[..<cut].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return L10n.tr("远端 %@", String(target[target.index(after: cut)...])) }
        return L10n.tr("%@（经远端）", target)
    }
}

/// One client connected to a local server, from the `TAILCAT_STATUS_LOOP` status dump.
public struct PeerStatus: Equatable, Sendable, Identifiable {
    public var publicKey: String
    /// Direct UDP endpoint; empty while the peer is reached through a DERP relay.
    public var curAddr: String
    /// DERP region code of the peer's home relay.
    public var relay: String
    public var rxBytes: Int64
    public var txBytes: Int64

    public var id: String { publicKey }
    public var isDirect: Bool { !curAddr.isEmpty }

    public init(publicKey: String, curAddr: String = "", relay: String = "", rxBytes: Int64 = 0, txBytes: Int64 = 0) {
        self.publicKey = publicKey
        self.curAddr = curAddr
        self.relay = relay
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }
}

public enum TunnelEvent: Equatable, Sendable {
    case listener(ListenerInfo)
    /// Banner line. `savedKey` is nil when the server runs with a fresh ephemeral key.
    case serverAddress(address: String, savedKey: String?)
    /// `--json` stdout line; carries no key information.
    case listenAddrJSON(String)
    case socks(String)
    case warning(String)
    case peers([PeerStatus])
}

/// Reads tailcat's output. The formats come from cmd/tailcat and are printed unconditionally:
/// `# forwarding <listen> -> remote <target>` (forward), `# 🐈 Server listening with …: <addr>`
/// (serve/recv), `SOCKS running at <url>` (socks, via log.Printf so it has a timestamp prefix),
/// `# ⚠️ WARNING: …`, and the undocumented `status = {json}` dump behind TAILCAT_STATUS_LOOP=1.
public enum OutputParser {
    private static let forwardPrefix = "# forwarding "
    private static let forwardSeparator = " -> remote "

    public static func parse(_ line: String) -> TunnelEvent? {
        if let listener = parseListener(line) { return .listener(listener) }
        if let server = parseServerBanner(line) { return .serverAddress(address: server.address, savedKey: server.savedKey) }
        if let addr = parseListenAddrJSON(line) { return .listenAddrJSON(addr) }
        if let socks = parseSocks(line) { return .socks(socks) }
        if let warning = parseWarning(line) { return .warning(warning) }
        if let peers = parseStatusLine(line) { return .peers(peers) }
        return nil
    }

    public static func parseListener(_ line: String) -> ListenerInfo? {
        guard line.hasPrefix(forwardPrefix), let sep = line.range(of: forwardSeparator) else { return nil }
        let addr = String(line[line.index(line.startIndex, offsetBy: forwardPrefix.count)..<sep.lowerBound])
        let target = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty,
              let colon = addr.lastIndex(of: ":"),
              let port = Int(addr[addr.index(after: colon)...]) else { return nil }
        var host = String(addr[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }
        return ListenerInfo(host: host, port: port, target: target)
    }

    public static func parseServerBanner(_ line: String) -> (address: String, savedKey: String?)? {
        guard line.hasPrefix("#"), let r = line.range(of: "Server listening with ") else { return nil }
        let rest = line[r.upperBound...]
        if rest.hasPrefix("new address: ") {
            let addr = rest.dropFirst("new address: ".count).trimmingCharacters(in: .whitespaces)
            return addr.isEmpty ? nil : (addr, nil)
        }
        let savedPrefix = "saved key \""
        guard rest.hasPrefix(savedPrefix) else { return nil }
        let afterQuote = rest.dropFirst(savedPrefix.count)
        guard let end = afterQuote.range(of: "\": ") else { return nil }
        let name = String(afterQuote[..<end.lowerBound])
        let addr = afterQuote[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return addr.isEmpty ? nil : (addr, name)
    }

    public static func parseListenAddrJSON(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.contains("listenAddr"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addr = obj["listenAddr"] as? String, !addr.isEmpty else { return nil }
        return addr
    }

    public static func parseSocks(_ line: String) -> String? {
        guard let r = line.range(of: "SOCKS running at ") else { return nil }
        let url = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return url.isEmpty ? nil : url
    }

    public static func parseWarning(_ line: String) -> String? {
        guard line.hasPrefix("#"), let r = line.range(of: "WARNING: ") else { return nil }
        let text = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Parses `ipnstate.Status` JSON defensively: the dump is a debugging aid with no stability
    /// promise, so anything unexpected yields nil rather than wrong data.
    public static func parseStatusLine(_ line: String) -> [PeerStatus]? {
        guard let r = line.range(of: "status = {") else { return nil }
        let json = "{" + line[r.upperBound...]
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let peerMap: [String: Any]
        switch obj["Peer"] {
        case nil, is NSNull: return []
        case let map as [String: Any]: peerMap = map
        default: return nil
        }
        var peers: [PeerStatus] = []
        for (mapKey, value) in peerMap {
            guard let p = value as? [String: Any] else { continue }
            peers.append(PeerStatus(
                publicKey: (p["PublicKey"] as? String) ?? mapKey,
                curAddr: (p["CurAddr"] as? String) ?? "",
                relay: (p["Relay"] as? String) ?? "",
                rxBytes: (p["RxBytes"] as? NSNumber)?.int64Value ?? 0,
                txBytes: (p["TxBytes"] as? NSNumber)?.int64Value ?? 0))
        }
        return peers.sorted { $0.publicKey < $1.publicKey }
    }

    /// Errors that retrying cannot fix. tailcat reports these once during setup and exits;
    /// anything else is treated as transient and retried with backoff.
    public static func isPermanentFailure(_ lines: [String], kind: TunnelKind = .forward) -> Bool {
        lines.contains { line in
            // Usage errors print the help text (FLAGS sections) followed by the error.
            if line.hasPrefix("FLAGS") || line.contains("unknown flag") { return true }
            if line.contains("already exists") || line.contains(".private.json") { return true }
            switch kind {
            case .forward, .socks:
                return (line.contains("mapping") && line.contains("is invalid"))
                    || line.contains("listen on ")
                    || line.contains("address already in use")
            case .serve, .recv:
                return line.contains("invalid port or service")
                    || line.contains("--ssh-authorized-keys:")
                    || line.contains("in --allow")
                    || line.contains("exec command:")
                    || line.contains("--files")
                    || line.contains("not supported on")
                    || line.contains("no such file or directory")
                    || line.contains("not a directory")
            }
        }
    }
}
