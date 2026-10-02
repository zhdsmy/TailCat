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
        return parts.isEmpty ? L10n.tr("已解析") : parts.joined(separator: " · ")
    }
}

/// Parses a pasted CLI line or bare tc address into fields for the forward editor.
public struct ForwardImport: Equatable, Sendable {
    public var address: String
    public var mappings: [String]
    public var bind: String?
    public var key: String?
    public var openBrowser: Bool
    public var isCommand: Bool

    public init(address: String, mappings: [String] = [], bind: String? = nil, key: String? = nil,
                openBrowser: Bool = false, isCommand: Bool = false) {
        self.address = address
        self.mappings = mappings
        self.bind = bind
        self.key = key
        self.openBrowser = openBrowser
        self.isCommand = isCommand
    }

    /// Applies the imported destination and command options, returning a matching saved remote.
    @discardableResult
    public func apply(to rule: inout TunnelRule, remotes: [Remote]) -> UUID? {
        let remote = remotes.first { $0.address == address && $0.key == (key ?? "") }
        rule.remoteID = remote?.id
        rule.address = remote == nil ? address : ""
        rule.key = remote == nil ? (key ?? "") : ""
        if isCommand {
            rule.mappings = mappings
            rule.bind = bind ?? "127.0.0.1"
            rule.openBrowser = openBrowser
        }
        return remote?.id
    }

    /// Applies a pasted destination to a remote draft. A bare address clears any previously chosen key.
    public func apply(to remote: inout Remote) {
        remote.address = address
        remote.key = key ?? ""
    }
}

public enum ForwardImportError: Error, Equatable, Sendable, LocalizedError {
    case unrecognized
    case invalidQuoting
    case invalidAddress
    case invalidMapping
    case missingOptionValue(String)
    case unsupportedOption(String)
    case unsupportedShellSyntax

    public var errorDescription: String? {
        switch self {
        case .unrecognized: return L10n.tr("剪贴板里没有可识别的 tc 地址或 forward 命令")
        case .invalidQuoting: return L10n.tr("命令中的引号或转义不完整")
        case .invalidAddress: return L10n.tr("命令中的远端地址无效")
        case .invalidMapping: return L10n.tr("命令中包含无效的端口映射")
        case .missingOptionValue(let option): return L10n.tr("参数 %@ 缺少值", option)
        case .unsupportedOption(let option): return L10n.tr("无法导入参数 %@；请先移除它或在 TailCat 中单独配置", option)
        case .unsupportedShellSyntax: return L10n.tr("命令含有 shell 展开或操作符；请将字面值用单引号包住，或只粘贴单独的 forward 命令")
        }
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
    /// This is a tokenizer only: it understands shell quoting but never expands or executes shell syntax.
    public static func parseForward(_ raw: String) -> Result<ForwardImport, ForwardImportError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.unrecognized) }
        var tokens: [String]
        switch tokenize(text) {
        case .success(let parsed): tokens = parsed
        case .failure(let error): return .failure(error)
        }
        guard !tokens.isEmpty else { return .failure(.unrecognized) }
        if tokens.count == 1, looksLikeDestination(tokens[0]) {
            return .success(ForwardImport(address: tokens[0]))
        }
        if tokens[0] == "tailcat" { tokens.removeFirst() }
        guard !tokens.isEmpty else { return .failure(.unrecognized) }

        var key: String?
        var i = 0
        var sawForward = false
        while i < tokens.count {
            let t = tokens[i]
            if t == "forward" { sawForward = true; i += 1; break }
            if t.hasPrefix("--key=") {
                key = String(t.dropFirst("--key=".count)); i += 1; continue
            }
            if t == "--key" {
                guard i + 1 < tokens.count else { return .failure(.missingOptionValue(t)) }
                key = tokens[i + 1]; i += 2; continue
            }
            if t == "--derpmap-url" || t.hasPrefix("--derpmap-url=") {
                return .failure(.unsupportedOption("--derpmap-url"))
            }
            if t == "--verbose" || t == "--json" { i += 1; continue }
            if t.hasPrefix("-") { return .failure(.unsupportedOption(optionName(t))) }
            return .failure(.unrecognized)
        }
        guard sawForward else { return .failure(.unrecognized) }

        var bind = "127.0.0.1"
        var openBrowser = false
        while i < tokens.count {
            let t = tokens[i]
            if t.hasPrefix("--bind=") { bind = String(t.dropFirst("--bind=".count)); i += 1; continue }
            if t == "--bind" {
                guard i + 1 < tokens.count else { return .failure(.missingOptionValue(t)) }
                bind = tokens[i + 1]; i += 2; continue
            }
            if t == "--open-browser" { openBrowser = true; i += 1; continue }
            if t.hasPrefix("-") { return .failure(.unsupportedOption(optionName(t))) }
            break
        }

        guard i < tokens.count, looksLikeDestination(tokens[i]) else { return .failure(.invalidAddress) }
        let address = tokens[i]
        i += 1
        let mappings = Array(tokens[i...])
        guard mappings.allSatisfy({ MappingSpec.parse($0) != nil }) else { return .failure(.invalidMapping) }
        return .success(ForwardImport(address: address, mappings: mappings, bind: bind, key: key,
                                      openBrowser: openBrowser, isCommand: true))
    }

    /// Best-effort compatibility wrapper for callers that only need to recognise importable text.
    public static func importForward(_ raw: String) -> ForwardImport? {
        try? parseForward(raw).get()
    }

    public static func looksLikeAddress(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && !s.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    /// tc… bearer addresses, or a DNS name with a dot (TXT lookup). Rejects bare subcommand words.
    public static func looksLikeDestination(_ s: String) -> Bool {
        guard looksLikeAddress(s), !knownSubcommands.contains(s) else { return false }
        return s.hasPrefix("tc") || s.contains(".")
    }

    private static func optionName(_ token: String) -> String {
        String(token.prefix { $0 != "=" })
    }

    private static func tokenize(_ text: String) -> Result<[String], ForwardImportError> {
        enum Quote { case none, single, double }
        var quote = Quote.none
        var tokens: [String] = []
        var token = ""
        var started = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch quote {
            case .single:
                if c == "'" { quote = .none } else { token.append(c) }
            case .double:
                if c == "\\" {
                    guard i + 1 < chars.count else { return .failure(.invalidQuoting) }
                    let next = chars[i + 1]
                    if next == "\"" || next == "\\" || next == "$" || next == "`" {
                        token.append(next); i += 1
                    } else {
                        token.append(c)
                    }
                } else if c == "\"" {
                    quote = .none
                } else if c == "$" || c == "`" {
                    return .failure(.unsupportedShellSyntax)
                } else {
                    token.append(c)
                }
            case .none:
                if c.isWhitespace {
                    if started { tokens.append(token); token = ""; started = false }
                } else if c == "'" {
                    quote = .single; started = true
                } else if c == "\"" {
                    quote = .double; started = true
                } else if c == "\\" {
                    guard i + 1 < chars.count else { return .failure(.invalidQuoting) }
                    i += 1; token.append(chars[i]); started = true
                } else if "$`".contains(c) || ";|&<>()".contains(c) {
                    return .failure(.unsupportedShellSyntax)
                } else {
                    token.append(c); started = true
                }
            }
            i += 1
        }
        guard case .none = quote else { return .failure(.invalidQuoting) }
        if started { tokens.append(token) }
        return .success(tokens)
    }
}
