import Foundation

public enum TunnelKind: String, Codable, Sendable, CaseIterable {
    case forward
    case serve
    case recv
    case socks

    /// Client kinds dial a remote server; they are health-checked and restarted on wake/network
    /// changes. Server kinds are left alone so an ephemeral-key address does not change under users.
    public var isClient: Bool {
        switch self {
        case .forward, .socks: return true
        case .serve, .recv: return false
        }
    }

    public var label: String {
        switch self {
        case .forward: return "转发"
        case .serve: return "服务"
        case .recv: return "收件箱"
        case .socks: return "SOCKS"
        }
    }

    public var systemImage: String {
        switch self {
        case .forward: return "arrow.left.arrow.right"
        case .serve: return "server.rack"
        case .recv: return "tray.and.arrow.down"
        case .socks: return "network"
        }
    }
}

public enum FilesMode: String, Codable, Sendable, CaseIterable {
    case ro, rw, wo, woPlus = "wo+"

    public var label: String {
        switch self {
        case .ro: return "只读"
        case .rw: return "读写"
        case .wo: return "只写投递箱（扁平）"
        case .woPlus: return "只写投递箱（递归）"
        }
    }
}

public enum RuleIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyName
    case invalidAddress
    case noMappings
    case openBrowserNeedsOneMapping
    case invalidMapping(String)
    case invalidBind
    case invalidKey
    case noServices
    case invalidService(String)
    case sshNeedsAuthorizedKeys
    case invalidAuthorizedKeys
    case unsupportedKeySource(String)
    case sshConflict
    case invalidAllow(String)
    case filesNeedsDirectory
    case invalidDirectory
    case invalidExec
    case invalidListen

    public var description: String {
        switch self {
        case .emptyName: return "名称不能为空"
        case .invalidAddress: return "地址不能为空，不能含空白字符，也不能以 - 开头"
        case .noMappings: return "至少需要一条端口映射"
        case .openBrowserNeedsOneMapping: return "--open-browser 必须且只能搭配一条端口映射"
        case .invalidMapping(let m): return "端口映射格式不对：\(m)（应为 8080、18080:8080 或 3306:192.168.1.10:3306）"
        case .invalidBind: return "监听地址不能为空，不能含空白字符，也不能以 - 开头"
        case .invalidKey: return "Key 名称不能含空白；路径可含空格。均不能以 - 开头或含换行、空字符"
        case .noServices: return "至少需要一项服务（端口、服务名、共享目录或 exec 命令）"
        case .invalidService(let s): return "无效的服务项：\(s)"
        case .sshNeedsAuthorizedKeys: return "ssh 服务必须配置授权公钥来源（--ssh-authorized-keys）"
        case .invalidAuthorizedKeys: return "授权公钥来源不能含换行，也不能以 - 开头"
        case .unsupportedKeySource(let s): return "tailcat 不支持这种公钥来源：\(s)（GitHub 账号写成 用户名@github）"
        case .sshConflict: return "ssh 与 no-auth-ssh 不能同时开启"
        case .invalidAllow(let s): return "允许列表项无效：\(s)（应为 nodekey:… 或 none）"
        case .filesNeedsDirectory: return "files 服务需要指定共享目录（否则会共享 App 的工作目录）"
        case .invalidDirectory: return "目录必须是绝对路径"
        case .invalidExec: return "exec 需要命令（每行一个参数，第一行是程序）"
        case .invalidListen: return "SOCKS 监听地址不能为空，不能含空白字符，也不能以 - 开头"
        }
    }
}

/// A saved tunnel: one long-running `tailcat forward|serve|recv|socks` process. Stored as JSON;
/// decoding tolerates missing fields so newer app versions can add options without invalidating
/// older files (a v1 file has no `kind` and decodes as forward rules).
public struct TunnelRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TunnelKind

    /// Client kinds dial the server of this Remote. Rules saved before remotes existed carry an
    /// inline `address`/`key`, which `RemoteMigration` moves into a Remote.
    public var remoteID: UUID?
    /// Inline tc… address (or DNS name); only used until migrated into a Remote.
    public var address: String
    /// Server kinds: `--key` for the server identity ("" = tailcat's `default` if saved, else
    /// ephemeral; "new" = always ephemeral). Client kinds: inline client key until migrated.
    public var key: String

    // forward
    public var mappings: [String]
    public var bind: String
    public var openBrowser: Bool

    // serve
    public var services: [String]
    /// Comma-separated `nodekey:…` list, or `none`. Empty allows every client.
    public var allow: String
    public var sshAuthorizedKeys: String
    public var filesDir: String
    public var filesMode: FilesMode
    public var fullAddress: Bool
    /// argv after `--`; never joined into a shell string.
    public var execArgs: [String]

    // recv
    public var recvDir: String
    public var acceptDirs: Bool

    // socks
    public var socksListen: String

    // supervision
    public var autoRestart: Bool
    public var healthCheck: Bool
    public var autoStart: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: TunnelKind = .forward,
        remoteID: UUID? = nil,
        address: String = "",
        key: String = "",
        mappings: [String] = [],
        bind: String = "127.0.0.1",
        openBrowser: Bool = false,
        services: [String] = [],
        allow: String = "",
        sshAuthorizedKeys: String = "",
        filesDir: String = "",
        filesMode: FilesMode = .ro,
        fullAddress: Bool = false,
        execArgs: [String] = [],
        recvDir: String = "",
        acceptDirs: Bool = false,
        socksListen: String = "127.0.0.1:1080",
        autoRestart: Bool = true,
        healthCheck: Bool = true,
        autoStart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.remoteID = remoteID
        self.address = address
        self.key = key
        self.mappings = mappings
        self.bind = bind
        self.openBrowser = openBrowser
        self.services = services
        self.allow = allow
        self.sshAuthorizedKeys = sshAuthorizedKeys
        self.filesDir = filesDir
        self.filesMode = filesMode
        self.fullAddress = fullAddress
        self.execArgs = execArgs
        self.recvDir = recvDir
        self.acceptDirs = acceptDirs
        self.socksListen = socksListen
        self.autoRestart = autoRestart
        self.healthCheck = healthCheck
        self.autoStart = autoStart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(TunnelKind.self, forKey: .kind) ?? .forward
        remoteID = try c.decodeIfPresent(UUID.self, forKey: .remoteID)
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        mappings = try c.decodeIfPresent([String].self, forKey: .mappings) ?? []
        bind = try c.decodeIfPresent(String.self, forKey: .bind) ?? "127.0.0.1"
        openBrowser = try c.decodeIfPresent(Bool.self, forKey: .openBrowser) ?? false
        services = try c.decodeIfPresent([String].self, forKey: .services) ?? []
        allow = try c.decodeIfPresent(String.self, forKey: .allow) ?? ""
        sshAuthorizedKeys = try c.decodeIfPresent(String.self, forKey: .sshAuthorizedKeys) ?? ""
        filesDir = try c.decodeIfPresent(String.self, forKey: .filesDir) ?? ""
        filesMode = try c.decodeIfPresent(FilesMode.self, forKey: .filesMode) ?? .ro
        fullAddress = try c.decodeIfPresent(Bool.self, forKey: .fullAddress) ?? false
        execArgs = try c.decodeIfPresent([String].self, forKey: .execArgs) ?? []
        recvDir = try c.decodeIfPresent(String.self, forKey: .recvDir) ?? ""
        acceptDirs = try c.decodeIfPresent(Bool.self, forKey: .acceptDirs) ?? false
        socksListen = try c.decodeIfPresent(String.self, forKey: .socksListen) ?? "127.0.0.1:1080"
        autoRestart = try c.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? true
        healthCheck = try c.decodeIfPresent(Bool.self, forKey: .healthCheck) ?? true
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }

    // MARK: Derived

    public var cleanedMappings: [String] { Self.cleaned(mappings) }

    /// Service list with comma-separated entries split out, the way `tailcat serve` reads it.
    public var cleanedServices: [String] {
        Self.cleaned(services.flatMap { $0.split(separator: ",").map(String.init) })
    }

    public var cleanedExecArgs: [String] { execArgs.filter { !$0.isEmpty } }

    /// Services that hand out access to whoever holds the address unless `--allow` restricts clients.
    public var needsAllowWarning: Bool {
        guard kind == .serve, allow.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let s = Set(cleanedServices)
        let execServed = !cleanedExecArgs.isEmpty && !s.contains("ssh")
        return s.contains("no-auth-ssh") || s.contains("exec") || s.contains("exit-node")
            || s.contains("all") || execServed
    }

    /// Whether a server is safe to reach by a public address (DNS TXT record): `--allow` restricts
    /// clients, or the only thing served is the key-authenticated `ssh` service. Plain ports (even
    /// 22 to a local sshd), files and the other services are open to anyone who reads the record.
    public var authenticatesEveryClient: Bool {
        guard kind == .serve else { return true }
        if !allow.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return cleanedServices == ["ssh"] && filesDir.isEmpty
            && !sshAuthorizedKeys.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `--key=new`: a fresh address on every (re)start.
    public var isEphemeralServer: Bool { !kind.isClient && key == "new" }

    /// Server identity depends on whether a saved `default` key exists.
    public var mayBeEphemeralServer: Bool { !kind.isClient && (key.isEmpty || key == "new") }

    public func duplicate() -> TunnelRule {
        var copy = self
        copy.id = UUID()
        copy.name += " 副本"
        copy.autoStart = false
        return copy
    }

    // MARK: Validation

    public func validate() -> [RuleIssue] {
        var issues: [RuleIssue] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyName) }
        if !key.isEmpty && !Self.isSafeKey(key) { issues.append(.invalidKey) }

        switch kind {
        case .forward:
            if remoteID == nil && !Self.isSafeToken(address) { issues.append(.invalidAddress) }
            if cleanedMappings.isEmpty && !openBrowser { issues.append(.noMappings) }
            if openBrowser && cleanedMappings.count != 1 { issues.append(.openBrowserNeedsOneMapping) }
            for m in cleanedMappings where MappingSpec.parse(m) == nil { issues.append(.invalidMapping(m)) }
            if !Self.isSafeToken(bind) { issues.append(.invalidBind) }
        case .serve:
            let services = cleanedServices
            if services.isEmpty && filesDir.isEmpty && cleanedExecArgs.isEmpty { issues.append(.noServices) }
            for s in services where !ServeItem.isValid(s) { issues.append(.invalidService(s)) }
            let sshKeys = sshAuthorizedKeys.trimmingCharacters(in: .whitespaces)
            if services.contains("ssh") && sshKeys.isEmpty { issues.append(.sshNeedsAuthorizedKeys) }
            if sshKeys.hasPrefix("-") || sshKeys.contains(where: \.isNewline) { issues.append(.invalidAuthorizedKeys) }
            // tailcat reads anything that is not `user@github` or a key line as a file path, so these
            // forms (once suggested by this app) fail at startup.
            for source in Self.cleaned(sshKeys.split(separator: ",").map(String.init))
            where ["github:", "http://", "https://"].contains(where: { source.hasPrefix($0) }) {
                issues.append(.unsupportedKeySource(source))
            }
            if services.contains("ssh") && services.contains("no-auth-ssh") { issues.append(.sshConflict) }
            for entry in Self.allowEntries(allow) where !Self.isValidAllowEntry(entry) {
                issues.append(.invalidAllow(entry))
            }
            if services.contains("files") && filesDir.isEmpty { issues.append(.filesNeedsDirectory) }
            if !filesDir.isEmpty && !Self.isAbsolutePath(filesDir) { issues.append(.invalidDirectory) }
            if services.contains("exec") && cleanedExecArgs.isEmpty { issues.append(.invalidExec) }
        case .recv:
            if !Self.isAbsolutePath(recvDir) { issues.append(.invalidDirectory) }
        case .socks:
            if remoteID == nil && !address.isEmpty && !Self.isSafeToken(address) { issues.append(.invalidAddress) }
            if !Self.isSafeToken(socksListen) { issues.append(.invalidListen) }
        }
        return issues
    }

    public static func allowEntries(_ allow: String) -> [String] {
        cleaned(allow.split(separator: ",").map(String.init))
    }

    public static func isValidAllowEntry(_ entry: String) -> Bool {
        entry == "none" || Contact.isValidPublicKey(entry)
    }

    // MARK: Command lines

    /// argv for the long-running process. Values are passed straight to exec (no shell), so the
    /// only injection risk is a value parsed as a flag; validate() rejects leading "-".
    /// `remote` supplies the destination for client kinds when `remoteID` is set.
    public func arguments(settings: AppSettings = AppSettings(), remote: Remote? = nil) -> [String] {
        switch kind {
        case .forward:
            let id = identity(remote: remote)
            var args = settings.globalFlagArguments(key: id.key)
            args.append(contentsOf: ["forward", "--bind=\(bind)"])
            if openBrowser { args.append("--open-browser") }
            args.append(id.address)
            args.append(contentsOf: cleanedMappings)
            return args
        case .socks:
            let id = identity(remote: remote)
            var args = settings.globalFlagArguments(key: id.key)
            args.append(contentsOf: ["socks", "--listen=\(socksListen)"])
            if !id.address.isEmpty { args.append(id.address) }
            return args
        case .serve:
            // --json makes the address available on stdout as well as in the stderr banner.
            var args = settings.globalFlagArguments(key: key) + ["--json", "serve"]
            if fullAddress { args.append("--full-address") }
            let allowValue = Self.allowEntries(allow).joined(separator: ",")
            if !allowValue.isEmpty { args.append("--allow=\(allowValue)") }
            let sshKeys = sshAuthorizedKeys.trimmingCharacters(in: .whitespaces)
            if !sshKeys.isEmpty { args.append("--ssh-authorized-keys=\(sshKeys)") }
            // Giving --files implies the files service; the mode suffix is always explicit so a
            // path that happens to end in ":rw" is not misread.
            if !filesDir.isEmpty { args.append("--files=\(filesDir):\(filesMode.rawValue)") }
            args.append(contentsOf: cleanedServices)
            if !cleanedExecArgs.isEmpty { args.append("--"); args.append(contentsOf: cleanedExecArgs) }
            return args
        case .recv:
            var args = settings.globalFlagArguments(key: key) + ["--json", "recv"]
            if acceptDirs { args.append("--accept-dirs") }
            args.append(recvDir)
            return args
        }
    }

    public func identity(remote: Remote?) -> ClientIdentity {
        if let remote, remote.id == remoteID { return remote.identity }
        return ClientIdentity(address: address, key: key)
    }

    /// Equivalent command a user could paste into a terminal.
    public func cliCommand(remote: Remote? = nil, settings: AppSettings = AppSettings()) -> String {
        let args = arguments(settings: settings, remote: remote).filter { $0 != "--json" }
        return (["tailcat"] + args).map(ShellQuote.quote).joined(separator: " ")
    }

    /// Commands a peer can run against this server's address.
    public func peerCommands(serverAddress: String) -> [String] {
        var cmds: [String] = []
        switch kind {
        case .serve:
            let services = cleanedServices
            let ports = services.compactMap(ServeItem.servedPort)
            if !ports.isEmpty {
                cmds.append("tailcat forward \(serverAddress) " + ports.map(String.init).joined(separator: " "))
            }
            if services.contains("ssh") || services.contains("no-auth-ssh") {
                cmds.append("tailcat ssh \(serverAddress)")
            }
            if !filesDir.isEmpty || services.contains("ssh") || services.contains("no-auth-ssh") {
                // ls speaks SFTP without SSH credentials, so it cannot list a key-authenticated ssh
                // server; cp goes through the system scp and its keys.
                if !filesDir.isEmpty || services.contains("no-auth-ssh") {
                    cmds.append("tailcat ls -l \(serverAddress)")
                }
                if filesMode == .ro || filesMode == .rw {
                    cmds.append("tailcat cp \(serverAddress):<文件> .")
                }
                if filesMode != .ro { cmds.append("tailcat cp <文件> \(serverAddress):") }
            }
            if services.contains("exit-node") {
                cmds.append("tailcat socks \(serverAddress)")
            }
            if services.contains("perf") { cmds.append("tailcat perf \(serverAddress)") }
            cmds.append("tailcat ping \(serverAddress)")
        case .recv:
            cmds.append("tailcat cp <文件> \(serverAddress):")
            if acceptDirs { cmds.append("tailcat cp -r <目录> \(serverAddress):") }
        case .forward, .socks:
            break
        }
        return cmds
    }

    // MARK: Helpers

    /// Key paths may contain spaces: argv preserves them without shell interpretation.
    static func isSafeKey(_ s: String) -> Bool {
        !s.hasPrefix("-") && !s.contains(where: { $0.isNewline || $0 == "\0" })
            && (s.contains("/") || !s.contains(where: \.isWhitespace))
    }

    static func isSafeToken(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && !s.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    static func isAbsolutePath(_ s: String) -> Bool {
        s.hasPrefix("/") && !s.contains(where: \.isNewline)
    }

    private static func cleaned(_ items: [String]) -> [String] {
        items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Destination and client key for a client-side tailcat command.
public struct ClientIdentity: Equatable, Sendable {
    public var address: String
    /// `--key` value; empty lets tailcat use `client-default` if saved, else an ephemeral key.
    public var key: String

    public init(address: String, key: String = "") {
        self.address = address
        self.key = key
    }

    public func pingArguments(timeoutSeconds: Int, untilDirect: Bool = false,
                              settings: AppSettings = AppSettings()) -> [String] {
        var args = settings.globalFlagArguments(key: key)
        args.append("ping")
        if untilDirect { args.append("--until-direct") }
        args.append("--timeout=\(timeoutSeconds)s")
        args.append(address)
        return args
    }
}
