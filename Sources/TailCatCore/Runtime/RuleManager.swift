import Combine
import Foundation

/// Latest reachability of a remote, from a manual ping or any rule's health check.
public struct RemotePing: Equatable, Sendable {
    /// nil: the server did not answer.
    public var result: PingResult?
    public var at: Date

    public init(result: PingResult?, at: Date = Date()) {
        self.result = result
        self.at = at
    }
}

/// Source of truth for the UI: saved rules (one `TunnelRunner` each), remotes, contacts, and what
/// the app knows about tailcat keys.
@MainActor
public final class RuleManager: ObservableObject {
    @Published public private(set) var runners: [TunnelRunner] = []
    @Published public private(set) var remotes: [Remote] = []
    @Published public private(set) var contacts: [Contact] = []
    @Published public private(set) var keyMetas: [KeyMeta] = []
    /// Key names from `genkey --list`.
    @Published public private(set) var savedKeys: [String] = []
    @Published public private(set) var loadError: String?
    @Published public private(set) var binaryPath: String?
    @Published public private(set) var versionText: String?
    @Published public private(set) var tailcatVersion: TailcatVersion?
    @Published public private(set) var capabilities = TailcatCapabilities()
    /// Files that arrived in a recv rule's directory since the user last looked.
    @Published public private(set) var inbox: [UUID: [String]] = [:]
    @Published public private(set) var remotePings: [UUID: RemotePing] = [:]
    @Published public private(set) var pingingRemotes: Set<UUID> = []

    /// (title, body) for failure / health alerts.
    public var onNotify: ((String, String) -> Void)?
    /// A recv rule's directory gained items (full URLs).
    public var onFilesReceived: ((TunnelRule, [URL]) -> Void)?

    public let cli: TailcatCLI
    public let remoteDirectory = RemoteDirectory()
    private let store: RuleStore
    private let remoteStore: ListStore<Remote>
    private let contactStore: ListStore<Contact>
    private let keyMetaStore: ListStore<KeyMeta>
    private let pids: PIDTracker
    private let makeConfig: (RemoteDirectory) -> RunnerConfig
    private let locator: BinaryLocator
    private var runnerObservers: [UUID: [AnyCancellable]] = [:]
    private var watchers: [UUID: DirectoryWatcher] = [:]
    private var livePIDs: [String: PIDTracker.Identity] = [:]
    private let events = SystemEvents()

    public init(
        store: RuleStore = RuleStore(directory: RuleStore.defaultDirectory()),
        locator: BinaryLocator = BinaryLocator(),
        settings: AppSettings = AppSettings(),
        makeConfig: ((RemoteDirectory) -> RunnerConfig)? = nil
    ) {
        self.store = store
        self.locator = locator
        self.cli = TailcatCLI(locator: locator, settings: settings)
        self.pids = PIDTracker(directory: store.directory)
        remoteStore = ListStore(fileURL: store.directory.appendingPathComponent("remotes.json"))
        contactStore = ListStore(fileURL: store.directory.appendingPathComponent("contacts.json"))
        keyMetaStore = ListStore(fileURL: store.directory.appendingPathComponent("key-meta.json"))
        self.makeConfig = makeConfig ?? { RunnerConfig.live(locator: locator, remotes: $0, settings: settings) }
    }

    public var rules: [TunnelRule] { runners.map(\.rule) }

    public func runner(id: UUID?) -> TunnelRunner? {
        guard let id else { return nil }
        return runners.first { $0.id == id }
    }

    // MARK: Lifecycle

    /// Reaps orphans from a previous run, loads data (migrating inline client addresses into
    /// remotes), starts `autoStart` rules, and begins listening for wake / network changes.
    public func bootstrap() {
        pids.reapOrphans()
        refreshBinary()
        var errors: [String] = []
        func load<T>(_ what: () throws -> [T]) -> [T] {
            do { return try what() } catch { errors.append(error.localizedDescription); return [] }
        }
        remotes = load(remoteStore.load)
        contacts = load(contactStore.load)
        keyMetas = load(keyMetaStore.load)
        let loaded = load(store.load)
        if !errors.isEmpty { loadError = errors.joined(separator: "\n") }
        let migrated = RemoteMigration.migrate(rules: loaded, remotes: remotes)
        // Migrated rules no longer hold their addresses, so they are adopted (and saved) only once
        // the remotes holding them are on disk; otherwise the inline rules keep working as they are.
        let adopted = migrated.changed && persist(migrated.remotes, to: remoteStore)
        if adopted { remotes = migrated.remotes }
        remoteDirectory.set(remotes)
        for rule in adopted ? migrated.rules : loaded { attach(rule) }
        if adopted { persist() }

        for runner in runners where runner.rule.autoStart { runner.start() }
        events.start { [weak self] reason in self?.restartActive(reason: reason) }
        Task { await refreshTailcatInfo() }
    }

    public func shutdown() {
        events.stop()
        for watcher in watchers.values { watcher.stop() }
        for runner in runners { runner.terminateSynchronously() }
        pids.save([:])
    }

    public func refreshBinary() {
        binaryPath = locator.locate()?.path
    }

    /// Version, capabilities and saved keys; re-run after the tailcat path changes.
    public func refreshTailcatInfo() async {
        refreshBinary()
        versionText = await cli.version()
        let (version, caps) = await cli.capabilities()
        tailcatVersion = version
        capabilities = caps
        await refreshKeys()
    }

    public func refreshKeys() async {
        if case .success(let names) = await cli.listKeys() { savedKeys = names }
    }

    // MARK: Rules

    public func add(_ rule: TunnelRule) {
        attach(adoptInlineRemote(rule))
        persist()
    }

    public func update(_ rule: TunnelRule) {
        runner(id: rule.id)?.update(rule: adoptInlineRemote(rule))
        persist()
        objectWillChange.send()
    }

    public func remove(id: UUID) {
        guard let runner = runner(id: id) else { return }
        runner.stop()
        runnerObservers[id] = nil
        watchers.removeValue(forKey: id)?.stop()
        inbox[id] = nil
        runners.removeAll { $0.id == id }
        persist()
    }

    public func toggle(id: UUID) {
        guard let runner = runner(id: id) else { return }
        runner.state.isActive ? runner.stop() : runner.start()
    }

    /// Wake / network change. Only client kinds: restarting a server with an ephemeral key would
    /// hand out a new address, and servers recover their own sessions.
    public func restartActive(reason: String) {
        for runner in runners where runner.rule.kind.isClient && runner.state.isActive {
            runner.restart(reason: reason)
        }
    }

    public func clearInbox(id: UUID) {
        inbox[id] = nil
    }

    // MARK: Remotes

    public func remote(id: UUID?) -> Remote? {
        guard let id else { return nil }
        return remotes.first { $0.id == id }
    }

    public func rules(usingRemote id: UUID) -> [TunnelRule] {
        rules.filter { $0.remoteID == id }
    }

    public func saveRemote(_ remote: Remote) {
        let old = self.remote(id: remote.id)
        if let i = remotes.firstIndex(where: { $0.id == remote.id }) {
            remotes[i] = remote
        } else {
            remotes.append(remote)
        }
        remoteDirectory.set(remotes)
        persistRemotes()
        // Only address and key reach the tailcat command line.
        if let old, old.address != remote.address || old.key != remote.key {
            remotePings[remote.id] = nil
            for runner in runners where runner.rule.remoteID == remote.id {
                runner.restart(reason: "远端「\(remote.name)」已修改")
            }
        }
    }

    /// Refuses while rules still reference the remote.
    @discardableResult
    public func removeRemote(id: UUID) -> Bool {
        guard rules(usingRemote: id).isEmpty else { return false }
        remotes.removeAll { $0.id == id }
        remotePings[id] = nil
        remoteDirectory.set(remotes)
        persistRemotes()
        return true
    }

    /// Probes a remote and records the outcome in `remotePings`. Returns nil when the remote did not
    /// answer (or, with `untilDirect`, did not go direct in time).
    @discardableResult
    public func pingRemote(id: UUID, untilDirect: Bool = false) async -> PingResult? {
        guard let remote = remote(id: id), !pingingRemotes.contains(id) else { return nil }
        pingingRemotes.insert(id)
        defer { pingingRemotes.remove(id) }
        let result = await cli.ping(remote.identity, untilDirect: untilDirect, timeoutSeconds: untilDirect ? 20 : 10)
        // A failed --until-direct wait says nothing about relayed reachability; keep the last status.
        if result != nil || !untilDirect { remotePings[id] = RemotePing(result: result) }
        return result
    }

    // MARK: Contacts

    public func saveContact(_ contact: Contact) {
        if let i = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[i] = contact
        } else {
            contacts.append(contact)
        }
        persist(contacts, to: contactStore)
    }

    public func removeContact(id: UUID) {
        contacts.removeAll { $0.id == id }
        persist(contacts, to: contactStore)
    }

    public func contactName(forPublicKey key: String) -> String? {
        contacts.first { $0.publicKey == key }?.name
    }

    // MARK: Keys

    public func keyMeta(name: String) -> KeyMeta? {
        keyMetas.first { $0.name == name }
    }

    /// Merges what was just learned about a key; nil fields keep their previous value.
    public func recordKey(_ meta: KeyMeta) {
        var merged = meta
        if let old = keyMeta(name: meta.name) {
            merged.role = meta.role ?? old.role
            merged.address = meta.address ?? old.address
            merged.publicKey = meta.publicKey ?? old.publicKey
            merged.region = meta.region ?? old.region
        }
        keyMetas.removeAll { $0.name == meta.name }
        keyMetas.append(merged)
        keyMetas.sort { $0.name < $1.name }
        persist(keyMetas, to: keyMetaStore)
    }

    public func forgetKey(name: String) {
        keyMetas.removeAll { $0.name == name }
        persist(keyMetas, to: keyMetaStore)
    }

    // MARK: Private

    /// A rule pasted with an inline address (CLI import) becomes a reference to a remote.
    private func adoptInlineRemote(_ rule: TunnelRule) -> TunnelRule {
        let result = RemoteMigration.migrate(rules: [rule], remotes: remotes)
        guard result.changed else { return rule }
        if result.remotes.count != remotes.count {
            // The migrated rule drops its inline address; keep it unless the new remote is saved.
            guard persist(result.remotes, to: remoteStore) else { return rule }
            remotes = result.remotes
            remoteDirectory.set(remotes)
        }
        return result.rules[0]
    }

    private func attach(_ rule: TunnelRule) {
        let runner = TunnelRunner(rule: rule, config: makeConfig(remoteDirectory))
        runner.onPIDChange = { [weak self] id, pid in self?.trackPID(id: id, pid: pid) }
        runner.onNotify = { [weak self] title, body in self?.onNotify?(title, body) }
        // A rule's health check doubles as a reachability probe for its remote, failures included,
        // so a dead remote does not keep showing its last good ping.
        runner.onProbe = { [weak self, weak runner] result in
            guard let self, let rid = runner?.rule.remoteID else { return }
            self.remotePings[rid] = RemotePing(result: result)
        }
        runner.onServerAddress = { [weak self] _, address, savedKey in
            guard let savedKey else { return }
            self?.recordKey(KeyMeta(name: savedKey, role: .server, address: address))
        }
        let id = rule.id
        runnerObservers[id] = [
            // Re-publish so views observing the manager refresh when any runner changes.
            runner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            runner.$state.sink { [weak self, weak runner] state in
                guard let self, let runner else { return }
                self.syncWatcher(for: runner.rule, active: state.isActive)
            },
        ]
        runners.append(runner)
    }

    private func syncWatcher(for rule: TunnelRule, active: Bool) {
        guard rule.kind == .recv, active, !rule.recvDir.isEmpty else {
            watchers.removeValue(forKey: rule.id)?.stop()
            return
        }
        let url = URL(fileURLWithPath: rule.recvDir, isDirectory: true)
        if watchers[rule.id]?.url == url { return }
        watchers[rule.id]?.stop()
        let watcher = DirectoryWatcher(url: url) { [weak self] names in
            self?.filesArrived(ruleID: rule.id, names: names)
        }
        watcher.start()
        watchers[rule.id] = watcher
    }

    private func filesArrived(ruleID: UUID, names: [String]) {
        guard let rule = runner(id: ruleID)?.rule else { return }
        inbox[ruleID, default: []].append(contentsOf: names)
        let base = URL(fileURLWithPath: rule.recvDir, isDirectory: true)
        onFilesReceived?(rule, names.map { base.appendingPathComponent($0) })
    }

    private func trackPID(id: UUID, pid: Int32?) {
        livePIDs[id.uuidString] = pid.flatMap(PIDTracker.Identity.of)
        pids.save(livePIDs)
    }

    private func persist() {
        do { try store.save(rules) } catch { loadError = "保存失败：\(error.localizedDescription)" }
    }

    private func persistRemotes() {
        persist(remotes, to: remoteStore)
    }

    @discardableResult
    private func persist<T: Codable>(_ items: [T], to store: ListStore<T>) -> Bool {
        do { try store.save(items); return true } catch {
            loadError = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
