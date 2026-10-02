import Foundation

/// A named client public key, for picking `serve --allow` entries.
public struct Contact: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var publicKey: String

    public init(id: UUID = UUID(), name: String = "", publicKey: String = "") {
        self.id = id
        self.name = name
        self.publicKey = publicKey
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && Self.isValidPublicKey(publicKey)
    }

    /// `nodekey:` followed by 64 hex digits, the form `--allow` and `$TAILCAT_PEER_KEY` use.
    public static func isValidPublicKey(_ s: String) -> Bool {
        guard s.hasPrefix("nodekey:") else { return false }
        let hex = s.dropFirst("nodekey:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

public enum KeyRole: String, Codable, Sendable {
    case server
    case client

    public var label: String {
        switch self {
        case .server: return L10n.tr("服务端")
        case .client: return L10n.tr("客户端")
        }
    }
}

/// What the app has learned about a saved tailcat key. tailcat cannot print an existing server
/// key's address without starting a server, so the address is recorded whenever genkey or a
/// serve banner reveals it. The address is a credential: this file is 0600.
public struct KeyMeta: Codable, Identifiable, Equatable, Sendable {
    public var name: String
    public var role: KeyRole?
    public var address: String?
    public var publicKey: String?
    public var region: String?
    public var updatedAt: Date

    public var id: String { name }

    public init(name: String, role: KeyRole? = nil, address: String? = nil, publicKey: String? = nil,
                region: String? = nil, updatedAt: Date = Date()) {
        self.name = name
        self.role = role
        self.address = address
        self.publicKey = publicKey
        self.region = region
        self.updatedAt = updatedAt
    }

    /// Role when the app did not create the key: tailcat's own convention for client key names.
    public var effectiveRole: KeyRole? {
        if let role { return role }
        if name == "client-default" || name.hasPrefix("client") { return .client }
        if name == "default" { return .server }
        return nil
    }
}
