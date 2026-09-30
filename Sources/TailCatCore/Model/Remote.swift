import Foundation

public enum RemoteIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyName
    case invalidAddress
    case invalidKey
    case invalidUser

    public var description: String {
        switch self {
        case .emptyName: return "名称不能为空"
        case .invalidAddress: return "地址不能为空，不能含空白字符，也不能以 - 开头"
        case .invalidKey: return "Key 不能以 - 开头，也不能含空白字符"
        case .invalidUser: return "SSH 用户名只能包含字母、数字、. _ -，且不能以 - 开头"
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

    public init(id: UUID = UUID(), name: String = "", address: String = "", key: String = "", sshUser: String = "") {
        self.id = id
        self.name = name
        self.address = address
        self.key = key
        self.sshUser = sshUser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        sshUser = try c.decodeIfPresent(String.self, forKey: .sshUser) ?? ""
    }

    public var identity: ClientIdentity { ClientIdentity(address: address, key: key) }

    public func validate() -> [RemoteIssue] {
        var issues: [RemoteIssue] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyName) }
        if !TunnelRule.isSafeToken(address) { issues.append(.invalidAddress) }
        if !key.isEmpty && !TunnelRule.isSafeToken(key) { issues.append(.invalidKey) }
        if !sshUser.isEmpty && !Self.isValidUser(sshUser) { issues.append(.invalidUser) }
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
                remote = Remote(name: rule.name.isEmpty ? "远端 \(remotes.count + 1)" : rule.name,
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
