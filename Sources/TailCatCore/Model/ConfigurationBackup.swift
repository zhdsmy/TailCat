import Foundation

/// App configuration only. Never reads or embeds tailcat private key files.
public struct ConfigurationBackup: Codable, Sendable {
    public var version: Int = 1
    public var rules: [TunnelRule]
    public var remotes: [Remote]
    public var contacts: [Contact]

    public init(rules: [TunnelRule], remotes: [Remote], contacts: [Contact]) {
        self.rules = rules
        self.remotes = remotes
        self.contacts = contacts
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // A chosen export folder (e.g. Downloads) is not the app's private storage directory.
        try SecureFile.write(encoder.encode(self), to: url, secureDirectory: false)
    }

    public static func read(from url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10 * 1024 * 1024 else { throw CLIError(L10n.tr("备份文件超过 10 MB，请检查文件。")) }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard version == 1 else { throw RuleStoreError.unsupportedVersion(version) }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        try backup.validate()
        return backup
    }

    public func validate() throws {
        guard version == 1 else { throw RuleStoreError.unsupportedVersion(version) }
        guard Set(remotes.map(\.id)).count == remotes.count,
              Set(rules.map(\.id)).count == rules.count,
              Set(contacts.map(\.id)).count == contacts.count else {
            throw CLIError(L10n.tr("备份中存在重复标识，无法安全导入。"))
        }
        let remoteIDs = Set(remotes.map(\.id))
        for remote in remotes {
            if let issue = remote.validate().first { throw CLIError(L10n.tr("远端 %@：%@", remote.name, issue.description)) }
        }
        for rule in rules {
            if let issue = rule.validate().first { throw CLIError(L10n.tr("规则 %@：%@", rule.name, issue.description)) }
            if let id = rule.remoteID, !remoteIDs.contains(id) { throw CLIError(L10n.tr("规则引用的远端不在备份中。")) }
        }
        guard contacts.allSatisfy(\.isValid) else { throw CLIError(L10n.tr("备份包含无效联系人。")) }
    }
}

public struct ConfigurationImport: Identifiable, Sendable {
    public let id = UUID()
    public let rules: [TunnelRule]
    public let remotes: [Remote]
    public let contacts: [Contact]
    public let skipped: Int
    let originalRules: [TunnelRule]
    let originalRemotes: [Remote]
    let originalContacts: [Contact]

    /// Merge, preserving existing entries. Conflicting IDs are remapped along with rule references.
    /// Imported rules never start automatically; their commands and local paths need review first.
    public init(backup: ConfigurationBackup, rules: [TunnelRule], remotes: [Remote], contacts: [Contact]) throws {
        try backup.validate()
        originalRules = rules
        originalRemotes = remotes
        originalContacts = contacts
        var addedRemotes: [Remote] = []
        var addedRules: [TunnelRule] = []
        var addedContacts: [Contact] = []
        var remoteIDs: [UUID: UUID] = [:]
        for source in backup.remotes {
            if let existing = (remotes + addedRemotes).first(where: { existing in
                var copy = source; copy.id = existing.id
                return copy == existing
            }) {
                remoteIDs[source.id] = existing.id
            } else {
                var copy = source
                if remotes.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
                remoteIDs[source.id] = copy.id
                addedRemotes.append(copy)
            }
        }
        for source in backup.rules {
            var copy = source
            copy.autoStart = false
            if let id = copy.remoteID { copy.remoteID = remoteIDs[id] }
            let duplicate = (rules + addedRules).contains { existing in
                var normalized = existing; normalized.autoStart = false; normalized.id = copy.id
                return normalized == copy
            }
            if !duplicate {
                if rules.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
                addedRules.append(copy)
            }
        }
        for source in backup.contacts {
            if (contacts + addedContacts).contains(where: { $0.publicKey == source.publicKey }) { continue }
            var copy = source
            if contacts.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
            addedContacts.append(copy)
        }
        self.remotes = addedRemotes
        self.rules = addedRules
        self.contacts = addedContacts
        skipped = backup.rules.count + backup.remotes.count + backup.contacts.count
            - addedRules.count - addedRemotes.count - addedContacts.count
    }
}
