import Foundation

public enum RunState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case reconnecting(attempt: Int, retryAt: Date, reason: String)
    case failed(reason: String)

    /// The supervisor is (or will shortly be) keeping a tunnel process alive.
    public var isActive: Bool {
        switch self {
        case .starting, .running, .reconnecting: return true
        case .stopped, .failed: return false
        }
    }
}

public enum LaunchError: Error, Equatable, Sendable, CustomStringConvertible {
    case binaryNotFound
    case missingRemote

    public var description: String {
        switch self {
        case .binaryNotFound: return "找不到 tailcat，请先安装（brew install tailcat）或在设置里指定路径"
        case .missingRemote: return "引用的远端不存在，请编辑规则重新选择"
        }
    }
}

public struct LaunchSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]?
    /// Destination for health checks and manual pings; nil for server kinds and bare SOCKS.
    public var identity: ClientIdentity?

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil,
                identity: ClientIdentity? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.identity = identity
    }
}

/// Resolves `remoteID`s at launch time; shared between the main-actor manager and runner tasks.
public final class RemoteDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [UUID: Remote] = [:]

    public init(_ remotes: [Remote] = []) { set(remotes) }

    public func set(_ remotes: [Remote]) {
        lock.lock(); defer { lock.unlock() }
        byID = Dictionary(remotes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func remote(id: UUID?) -> Remote? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        return byID[id]
    }
}

public struct RunnerConfig: Sendable {
    public var backoff: BackoffPolicy
    public var healthInterval: TimeInterval
    public var healthFailureThreshold: Int
    public var terminateGrace: TimeInterval
    public var logCapacity: Int
    public var launch: @Sendable (TunnelRule) throws -> LaunchSpec
    /// Pings `spec.identity`; returns the parsed pong, or nil when the server does not answer.
    public var probe: @Sendable (LaunchSpec, _ untilDirect: Bool, _ timeoutSeconds: Int) async -> PingResult?

    public init(
        backoff: BackoffPolicy = BackoffPolicy(),
        healthInterval: TimeInterval = 30,
        healthFailureThreshold: Int = 3,
        terminateGrace: TimeInterval = 3,
        logCapacity: Int = 200,
        launch: @escaping @Sendable (TunnelRule) throws -> LaunchSpec,
        probe: @escaping @Sendable (LaunchSpec, _ untilDirect: Bool, _ timeoutSeconds: Int) async -> PingResult?
    ) {
        self.backoff = backoff
        self.healthInterval = healthInterval
        self.healthFailureThreshold = healthFailureThreshold
        self.terminateGrace = terminateGrace
        self.logCapacity = logCapacity
        self.launch = launch
        self.probe = probe
    }

    /// Real tailcat: locate the binary, build the rule's argv, health-check with `tailcat ping`.
    public static func live(locator: BinaryLocator, remotes: RemoteDirectory,
                            settings: AppSettings = AppSettings()) -> RunnerConfig {
        RunnerConfig(
            launch: { rule in
                guard let exe = locator.locate() else { throw LaunchError.binaryNotFound }
                let remote = remotes.remote(id: rule.remoteID)
                if rule.kind == .forward, rule.remoteID != nil, remote == nil { throw LaunchError.missingRemote }
                var environment: [String: String]?
                if rule.kind == .serve, settings.statusLoopEnabled {
                    environment = ProcessInfo.processInfo.environment.merging(["TAILCAT_STATUS_LOOP": "1"]) { $1 }
                }
                var identity: ClientIdentity?
                if rule.kind.isClient {
                    let id = rule.identity(remote: remote)
                    if !id.address.isEmpty { identity = id }
                }
                return LaunchSpec(executable: exe, arguments: rule.arguments(settings: settings, remote: remote),
                                  environment: environment, identity: identity)
            },
            probe: { spec, untilDirect, timeout in
                guard let identity = spec.identity else { return nil }
                return await TailcatCLI.ping(executable: spec.executable, identity: identity,
                                             timeoutSeconds: timeout, untilDirect: untilDirect, settings: settings)
            }
        )
    }
}

/// How a local server identified itself in its startup banner.
public enum ServerIdentity: Equatable, Sendable {
    case ephemeral
    case saved(String)
}

/// Supervises one rule: launches its tailcat process, restarts it with backoff when it exits, and
/// (client kinds) restarts it when the health check reports the server unreachable — `forward`
/// never exits on a dead tunnel, it just fails each new connection.
@MainActor
public final class TunnelRunner: ObservableObject, Identifiable {
    public nonisolated let id: UUID
    public private(set) var rule: TunnelRule

    @Published public private(set) var state: RunState = .stopped
    @Published public private(set) var listeners: [ListenerInfo] = []
    @Published public private(set) var serverAddress: String?
    @Published public private(set) var serverIdentity: ServerIdentity?
    @Published public private(set) var socksAddress: String?
    @Published public private(set) var warnings: [String] = []
    @Published public private(set) var peers: [PeerStatus] = []
    @Published public private(set) var log: [String] = []
    @Published public private(set) var lastPing: PingResult?
    @Published public private(set) var lastPingAt: Date?
    @Published public private(set) var pingBusy = false

    /// Called with the child pid when a process starts and with nil when it has exited.
    public var onPIDChange: ((UUID, Int32?) -> Void)?
    /// (title, body) for alerts the user should see even with the window closed.
    public var onNotify: ((String, String) -> Void)?
    /// Outcome of each health check and plain manual ping; nil when the server did not answer.
    public var onProbe: ((PingResult?) -> Void)?
    /// A server printed its address; `savedKey` is nil for an ephemeral key.
    public var onServerAddress: ((TunnelRule, String, String?) -> Void)?

    private let config: RunnerConfig
    private var task: Task<Void, Never>?
    private var generation = 0
    private var currentBox: ProcessBox?
    private var runTail: [String] = []

    public init(rule: TunnelRule, config: RunnerConfig) {
        self.id = rule.id
        self.rule = rule
        self.config = config
    }

    // MARK: Control

    public func start() {
        guard !state.isActive else { return }
        generation += 1
        let gen = generation
        let previous = task
        state = .starting
        clearRunInfo()
        task = Task { [weak self] in
            // A previous run may still be shutting down; wait so its listener ports are free.
            await previous?.value
            await self?.supervise(gen: gen)
        }
    }

    public func stop() {
        generation += 1
        task?.cancel()
        state = .stopped
        clearRunInfo()
    }

    public func restart(reason: String) {
        guard state.isActive else { return }
        appendLog("# \(reason)，重启")
        stop()
        start()
    }

    /// Applies edited settings; a running tunnel is restarted so they take effect.
    public func update(rule newRule: TunnelRule) {
        let changed = newRule != rule
        rule = newRule
        if changed, state.isActive { restart(reason: "配置已修改") }
    }

    /// Blocking stop for app quit, when no scheduled work will get a chance to run.
    public func terminateSynchronously(timeout: TimeInterval = 1.5) {
        generation += 1
        task?.cancel()
        state = .stopped
        currentBox?.terminateAndWait(timeout: timeout)
    }

    /// One-shot diagnostic ping; updates `lastPing` when successful.
    @discardableResult
    public func runPing(untilDirect: Bool = false, timeoutSeconds: Int = 10) async -> PingResult? {
        guard !pingBusy else { return lastPing }
        pingBusy = true
        defer { pingBusy = false }
        let spec: LaunchSpec
        do { spec = try config.launch(rule) } catch {
            appendLog("# 无法 ping：\(error)")
            return nil
        }
        guard spec.identity != nil else {
            appendLog("# 该规则没有目标地址，无法 ping")
            return nil
        }
        appendLog(untilDirect ? "# ping --until-direct…" : "# ping…")
        let result = await config.probe(spec, untilDirect, timeoutSeconds)
        // A failed --until-direct wait says nothing about relayed reachability.
        if result != nil || !untilDirect { onProbe?(result) }
        if let result {
            recordPing(result)
            appendLog("# \(result.detailLabel)")
        } else {
            appendLog(untilDirect ? "# 在超时内未获得直连路径" : "# ping 失败")
        }
        return result
    }

    // MARK: Supervision

    private func clearRunInfo() {
        listeners = []
        serverAddress = nil
        serverIdentity = nil
        socksAddress = nil
        warnings = []
        peers = []
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation }

    private func setState(_ gen: Int, _ new: RunState) {
        guard isCurrent(gen) else { return }
        state = new
    }

    private func supervise(gen: Int) async {
        var attempt = 0
        while isCurrent(gen) {
            let spec: LaunchSpec
            do { spec = try config.launch(rule) } catch {
                setState(gen, .failed(reason: "\(error)"))
                return
            }
            setState(gen, .starting)
            clearRunInfo()
            let outcome = await runOnce(gen: gen, spec: spec)
            guard isCurrent(gen) else { return }
            clearRunInfo()

            let reason = describe(outcome)
            appendLog("# 进程退出：\(reason)")

            if outcome.launchFailed || OutputParser.isPermanentFailure(outcome.tail, kind: rule.kind) || !rule.autoRestart {
                setState(gen, .failed(reason: reason))
                onNotify?(rule.name, "\(rule.kind.label)失败：\(reason)")
                return
            }

            if outcome.ranFor >= config.backoff.stableAfter { attempt = 0 }
            attempt += 1
            let delay = config.backoff.delay(forAttempt: attempt)
            setState(gen, .reconnecting(attempt: attempt,
                                        retryAt: Date().addingTimeInterval(delay),
                                        reason: reason))
            if attempt == 3 || attempt == 8 {
                onNotify?(rule.name, "正在重连（第 \(attempt) 次）：\(reason)")
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private struct Outcome {
        var status: Int32?
        var ranFor: TimeInterval
        var unhealthy: Bool
        var launchFailed: Bool
        var launchError: String?
        var tail: [String]
    }

    private func describe(_ outcome: Outcome) -> String {
        if let error = outcome.launchError { return "无法启动：\(error)" }
        if outcome.unhealthy { return "健康检查失败（服务端无响应）" }
        if let last = outcome.tail.last(where: { !$0.isEmpty }) { return last }
        return "退出码 \(outcome.status.map(String.init) ?? "?")"
    }

    private func runOnce(gen: Int, spec: LaunchSpec) async -> Outcome {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        if let env = spec.environment { process.environment = env }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { p in
            exitContinuation.yield(p.terminationStatus)
            exitContinuation.finish()
        }
        let box = ProcessBox(process)
        runTail = []
        let started = Date()

        do {
            try process.run()
        } catch {
            return Outcome(status: nil, ranFor: 0, unhealthy: false, launchFailed: true,
                           launchError: error.localizedDescription, tail: [])
        }
        // Process closes the parent's write ends itself (see ProcessRunner.run).
        currentBox = box
        onPIDChange?(rule.id, process.processIdentifier)

        let readers = [errPipe, outPipe].map { pipe in
            Task { [weak self] in
                for await line in PipeReader.lines(pipe.fileHandleForReading) {
                    self?.handleLine(line, gen: gen)
                }
            }
        }
        let health: Task<Void, Never>? = rule.kind.isClient && rule.healthCheck && spec.identity != nil
            ? Task { [weak self] in await self?.healthLoop(gen: gen, spec: spec, box: box) }
            : nil

        let status: Int32? = await withTaskCancellationHandler {
            if Task.isCancelled { box.terminate(grace: config.terminateGrace) }
            for await s in exits { return s }
            return nil
        } onCancel: { [grace = config.terminateGrace] in
            box.terminate(grace: grace)
        }

        health?.cancel()
        for reader in readers { await reader.value }
        if currentBox === box { currentBox = nil }
        onPIDChange?(rule.id, nil)

        return Outcome(status: status, ranFor: Date().timeIntervalSince(started),
                       unhealthy: box.markedUnhealthy, launchFailed: false, launchError: nil,
                       tail: runTail)
    }

    private func handleLine(_ line: String, gen: Int) {
        guard isCurrent(gen) else { return }
        let event = OutputParser.parse(line)
        // The status dump repeats every few seconds; keep it out of the log and failure tail.
        if case .peers(let list) = event {
            peers = list
            return
        }
        appendLog(line)
        runTail.append(line)
        if runTail.count > 20 { runTail.removeFirst(runTail.count - 20) }

        switch event {
        case .listener(let listener):
            if !listeners.contains(listener) { listeners.append(listener) }
            markRunning()
        case .serverAddress(let address, let savedKey):
            serverAddress = address
            serverIdentity = savedKey.map(ServerIdentity.saved) ?? .ephemeral
            onServerAddress?(rule, address, savedKey)
            markRunning()
        case .listenAddrJSON(let address):
            if serverAddress == nil { serverAddress = address }
            markRunning()
        case .socks(let url):
            socksAddress = url
            markRunning()
        case .warning(let text):
            if !warnings.contains(text) { warnings.append(text) }
        case .peers, nil:
            break
        }
    }

    private func markRunning() {
        if state == .starting { state = .running }
    }

    private func healthLoop(gen: Int, spec: LaunchSpec, box: ProcessBox) async {
        var failures = 0
        let interval = UInt64(config.healthInterval * 1_000_000_000)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: interval)
            if Task.isCancelled || !isCurrent(gen) { return }
            // Only judge a tunnel that came up; startup problems are handled by exit/backoff.
            guard state == .running else { failures = 0; continue }

            let result = await config.probe(spec, false, 10)
            if Task.isCancelled || !isCurrent(gen) { return }
            onProbe?(result)
            if let result {
                recordPing(result)
                failures = 0
            } else {
                failures += 1
            }
            if failures >= config.healthFailureThreshold {
                appendLog("# 健康检查连续失败 \(failures) 次，重启隧道进程")
                onNotify?(rule.name, "健康检查失败，正在重启隧道")
                box.markUnhealthy()
                box.terminate(grace: config.terminateGrace)
                return
            }
        }
    }

    private func recordPing(_ result: PingResult) {
        // Time first: `$lastPing` subscribers run during willSet and may read it.
        lastPingAt = Date()
        lastPing = result
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > config.logCapacity { log.removeFirst(log.count - config.logCapacity) }
    }
}
