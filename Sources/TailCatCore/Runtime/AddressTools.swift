import Foundation

/// Decoded fields from `tailcat parse` JSON.
public struct ParsedAddress: Equatable, Sendable {
    public var serverPublic: String?
    public var regionID: Int?
    public var regionHostnames: [String]

    public init(serverPublic: String? = nil, regionID: Int? = nil, regionHostnames: [String] = []) {
        self.serverPublic = serverPublic
        self.regionID = regionID
        self.regionHostnames = regionHostnames
    }

    public var summary: String {
        var parts: [String] = []
        if let serverPublic {
            let short = serverPublic.hasPrefix("nodekey:")
                ? "nodekey:" + String(serverPublic.dropFirst("nodekey:".count).prefix(12)) + "…"
                : serverPublic
            parts.append(short)
        }
        if let regionID {
            parts.append("region \(regionID)")
        } else if !regionHostnames.isEmpty {
            parts.append(regionHostnames.joined(separator: ","))
        }
        return parts.isEmpty ? "已解析" : parts.joined(separator: " · ")
    }
}

/// Parses a pasted CLI line or bare tc address into fields for the forward editor.
public struct ForwardImport: Equatable, Sendable {
    public var address: String
    public var mappings: [String]
    public var bind: String?
    public var key: String?

    public init(address: String, mappings: [String] = [], bind: String? = nil, key: String? = nil) {
        self.address = address
        self.mappings = mappings
        self.bind = bind
        self.key = key
    }
}

public enum AddressTools {
    /// Best-effort parse of `tailcat parse` JSON. Fields are optional because the wire format
    /// varies (region ID vs embedded Region nodes).
    public static func parseJSON(_ text: String) -> ParsedAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let serverPublic = obj["ServerPublic"] as? String
        let regionID = (obj["RegionID"] as? Int) ?? (obj["RegionID"] as? NSNumber)?.intValue
        var hosts: [String] = []
        if let regions = obj["Region"] as? [[String: Any]] {
            for region in regions {
                if let nodes = region["Nodes"] as? [[String: Any]] {
                    for node in nodes {
                        if let host = node["HostName"] as? String { hosts.append(host) }
                    }
                }
            }
        }
        if serverPublic == nil && regionID == nil && hosts.isEmpty { return nil }
        return ParsedAddress(serverPublic: serverPublic, regionID: regionID, regionHostnames: hosts)
    }

    private static let knownSubcommands: Set<String> = [
        "serve", "ping", "socks", "recv", "ssh", "cp", "ls", "forward", "browse",
        "parse", "resolve", "genkey", "printpub", "version", "readme", "perf",
    ]

    /// Recognises a bare tc… / DNS address or `tailcat [global-flags] forward [flags] <addr> <maps…>`.
    public static func importForward(_ raw: String) -> ForwardImport? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains(where: \.isWhitespace), looksLikeDestination(text) {
            return ForwardImport(address: text)
        }

        var tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }
        if tokens[0] == "tailcat" { tokens.removeFirst() }

        var key: String?
        var bind: String?
        var i = 0
        var sawForward = false
        while i < tokens.count {
            let t = tokens[i]
            if t == "forward" { sawForward = true; i += 1; break }
            if knownSubcommands.contains(t) { return nil }
            if t.hasPrefix("--key=") { key = String(t.dropFirst("--key=".count)); i += 1; continue }
            if t == "--key", i + 1 < tokens.count { key = tokens[i + 1]; i += 2; continue }
            if t.hasPrefix("--derpmap-url=") || t == "--verbose" || t == "--json" { i += 1; continue }
            if t == "--derpmap-url", i + 1 < tokens.count { i += 2; continue }
            if t.hasPrefix("-") { return nil }
            break
        }
        guard sawForward else { return nil }

        while i < tokens.count {
            let t = tokens[i]
            if t.hasPrefix("--bind=") { bind = String(t.dropFirst("--bind=".count)); i += 1; continue }
            if t == "--bind", i + 1 < tokens.count { bind = tokens[i + 1]; i += 2; continue }
            if t == "--open-browser" { i += 1; continue }
            break
        }

        guard i < tokens.count, looksLikeDestination(tokens[i]) else { return nil }
        let address = tokens[i]
        i += 1
        let mappings = Array(tokens[i...]).filter { MappingSpec.parse($0) != nil }
        return ForwardImport(address: address, mappings: mappings, bind: bind, key: key)
    }

    public static func looksLikeAddress(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && !s.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    /// tc… bearer addresses, or a DNS name with a dot (TXT lookup). Rejects bare subcommand words.
    public static func looksLikeDestination(_ s: String) -> Bool {
        guard looksLikeAddress(s), !knownSubcommands.contains(s) else { return false }
        return s.hasPrefix("tc") || s.contains(".")
    }

    private static func tokenize(_ text: String) -> [String] {
        // Simple whitespace split; quoted args are uncommon for the commands we import.
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
