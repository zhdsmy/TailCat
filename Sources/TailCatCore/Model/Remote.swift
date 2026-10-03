import Foundation

public enum RemoteIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyName
    case invalidAddress
    case invalidKey
    case invalidUser
    case invalidSSHPort
    case invalidServicePort

    public var description: String {
        switch self {
        case .emptyName: return L10n.tr("名称不能为空")
        case .invalidAddress: return L10n.tr("地址不能为空，不能含空白字符，也不能以 - 开头")
        case .invalidKey: return L10n.tr("Key 名称不能含空白；路径可含空格。均不能以 - 开头或含换行、空字符")
        case .invalidUser: return L10n.tr("SSH 用户名只能包含字母、数字、. _ -，且不能以 - 开头")
        case .invalidSSHPort: return L10n.tr("SSH 端口格式不对")
        case .invalidServicePort: return L10n.tr("网页和文件端口必须在 1–65535 之间")
        }
    }
}

/// A tailcat server this Mac connects to. The address is a bearer credential, so it lives in one
/// place (remotes.json, 0600) and client rules reference it by id.
public struct Remote: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    /// Client `--key`; empty = tailcat's `client-default` if saved, else ephemeral.
    public var key: String
    public var sshUser: String
    public var sshPort: String
    public var webPort: Int
    public var filePort: Int

    public init(id: UUID = UUID(), name: String = "", address: String = "", key: String = "", sshUser: String = "",
                sshPort: String = "", webPort: Int = 80, filePort: Int = 22) {
        self.id = id
        self.name = name
        self.address = address
        self.key = key
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.webPort = webPort
        self.filePort = filePort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        sshUser = try c.decodeIfPresent(String.self, forKey: .sshUser) ?? ""
        sshPort = try c.decodeIfPresent(String.self, forKey: .sshPort) ?? ""
        webPort = try c.decodeIfPresent(Int.self, forKey: .webPort) ?? 80
        filePort = try c.decodeIfPresent(Int.self, forKey: .filePort) ?? 22
    }

    public var identity: ClientIdentity { ClientIdentity(address: address, key: key) }

    public func validate() -> [RemoteIssue] {
        var issues: [RemoteIssue] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyName) }
        if !TunnelRule.isSafeToken(address) { issues.append(.invalidAddress) }
        if !key.isEmpty && !TunnelRule.isSafeKey(key) { issues.append(.invalidKey) }
        if !sshUser.isEmpty && !Self.isValidUser(sshUser) { issues.append(.invalidUser) }
        if !SSHLauncher.isValidPort(sshPort) { issues.append(.invalidSSHPort) }
        if !(1...65535).contains(webPort) || !(1...65535).contains(filePort) { issues.append(.invalidServicePort) }
        return issues
    }

    static func isValidUser(_ s: String) -> Bool {
        !s.hasPrefix("-") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}

public enum RemoteMigration {
    /// Moves inline client addresses into Remotes, reusing a Remote with the same address and key,
    /// and clears the inline copy so the credential is stored once. Server rules are untouched.
    public static func migrate(rules: [TunnelRule], remotes: [Remote]) -> (rules: [TunnelRule], remotes: [Remote], changed: Bool) {
        var rules = rules
        var remotes = remotes
        var changed = false
        for i in rules.indices where rules[i].kind.isClient {
            let rule = rules[i]
            if let rid = rule.remoteID, remotes.contains(where: { $0.id == rid }) { continue }
            let address = rule.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else {
                // Dangling reference with nothing to rebuild from: socks may run without a remote.
                if rule.remoteID != nil { rules[i].remoteID = nil; changed = true }
                continue
            }
            let remote: Remote
            if let existing = remotes.first(where: { $0.address == address && $0.key == rule.key }) {
                remote = existing
            } else {
                remote = Remote(name: rule.name.isEmpty ? L10n.tr("远端 %@", String(remotes.count + 1)) : rule.name,
                                address: address, key: rule.key)
                remotes.append(remote)
            }
            rules[i].remoteID = remote.id
            rules[i].address = ""
            rules[i].key = ""
            changed = true
        }
        return (rules, remotes, changed)
    }
}
