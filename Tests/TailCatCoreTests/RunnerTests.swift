import Foundation
import Testing
@testable import TailCatCore

@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private let fastBackoff = BackoffPolicy(base: 0.05, cap: 0.2, stableAfter: 60)
private let healthyPing = PingResult(latency: 0.001, path: .direct(endpoint: "1.2.3.4:5"))
private let listenerLine = "echo '# forwarding 127.0.0.1:4321 -> remote 80' >&2"

private func shConfig(
    script: @escaping @Sendable (TunnelRule) -> String,
    identity: ClientIdentity? = ClientIdentity(address: "tcx"),
    probe: @escaping @Sendable () -> PingResult? = { healthyPing },
    healthInterval: TimeInterval = 0.05
) -> RunnerConfig {
    RunnerConfig(
        backoff: fastBackoff,
        healthInterval: healthInterval,
        healthFailureThreshold: 2,
        terminateGrace: 0.5,
        launch: { rule in
            LaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script(rule)],
                       identity: rule.kind.isClient ? identity : nil)
        },
        probe: { _, _, _ in probe() })
}

private func shConfig(_ script: String, probe: @escaping @Sendable () -> PingResult? = { healthyPing }) -> RunnerConfig {
    shConfig(script: { _ in script }, probe: probe)
}

private func forwardRule(health: Bool = false, autoRestart: Bool = true) -> TunnelRule {
    TunnelRule(name: "t", address: "tcx", mappings: ["0:80"], autoRestart: autoRestart, healthCheck: health)
}

private func isFailed(_ state: RunState) -> Bool {
    if case .failed = state { return true }
    return false
}

/// Drives TunnelRunner with /bin/sh scripts standing in for tailcat.
@MainActor
@Suite struct RunnerTests {
    @Test func becomesRunningAndReportsListener() async {
        let runner = TunnelRunner(rule: forwardRule(), config: shConfig("\(listenerLine); exec sleep 30"))
        runner.start()
        #expect(await waitUntil { runner.state == .running })
        #expect(runner.listeners.first?.port == 4321)
        runner.stop()
        #expect(await waitUntil { runner.state == .stopped })
    }

    @Test func restartsWithBackoffWhenProcessExits() async {
        let runner = TunnelRunner(rule: forwardRule(), config: shConfig("echo 'connect: network unreachable' >&2; exit 1"))
        runner.start()
        let sawReconnect = await waitUntil {
            if case .reconnecting(let attempt, _, _) = runner.state { return attempt >= 2 }
            return false
        }
        #expect(sawReconnect)
        runner.stop()
    }

    @Test func permanentSetupErrorFailsInsteadOfLooping() async {
        let runner = TunnelRunner(rule: forwardRule(),
            config: shConfig("echo 'listen on 127.0.0.1:80: address already in use' >&2; exit 1"))
        var notes: [String] = []
        runner.onNotify = { _, body in notes.append(body) }
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
        #expect(notes.first?.hasPrefix("转发失败") == true)
    }

    @Test func noAutoRestartStopsAfterExit() async {
        let runner = TunnelRunner(rule: forwardRule(autoRestart: false), config: shConfig("exit 2"))
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
    }

    @Test func missingBinaryFails() async {
        var cfg = shConfig("")
        cfg.launch = { _ in throw LaunchError.binaryNotFound }
        let runner = TunnelRunner(rule: forwardRule(), config: cfg)
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
        #expect(runner.state == .failed(reason: LaunchError.binaryNotFound.description))
    }

    @Test func failedHealthCheckKillsAndRestartsTunnel() async {
        // The process never exits by itself, like a real `forward` with a dead tunnel.
        let runner = TunnelRunner(rule: forwardRule(health: true),
                                  config: shConfig("\(listenerLine); exec sleep 30", probe: { nil }))
        runner.start()
        #expect(await waitUntil { runner.log.contains { $0.contains("健康检查失败") } })
        runner.stop()
    }

    @Test func healthyProbeLeavesTunnelAlone() async {
        let runner = TunnelRunner(rule: forwardRule(health: true), config: shConfig("\(listenerLine); exec sleep 30"))
        runner.start()
        #expect(await waitUntil { runner.state == .running })
        #expect(await waitUntil { runner.lastPing == healthyPing })
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(runner.state == .running)
        runner.stop()
    }

    @Test func manualPing() async {
        let runner = TunnelRunner(rule: forwardRule(), config: shConfig("exit 0"))
        #expect(await runner.runPing() == healthyPing)
        #expect(runner.lastPing == healthyPing)
        #expect(runner.lastPingAt.map { Date().timeIntervalSince($0) < 5 } == true)
        #expect(runner.log.last?.contains("直连") == true)

        let server = TunnelRunner(rule: TunnelRule(name: "s", kind: .serve, services: ["22"]), config: shConfig("exit 0"))
        #expect(await server.runPing() == nil)
    }

    @Test func pidCallbackFiresOnStartAndExit() async {
        let runner = TunnelRunner(rule: forwardRule(), config: shConfig("\(listenerLine); exec sleep 30"))
        var events: [Int32?] = []
        runner.onPIDChange = { _, pid in events.append(pid) }
        runner.start()
        #expect(await waitUntil { runner.state == .running })
        runner.stop()
        #expect(await waitUntil { events.count >= 2 })
        #expect(events.first! != nil)
        #expect(events.last! == nil)
    }

    @Test func editingRestartsActiveRunner() async {
        let runner = TunnelRunner(rule: forwardRule(), config: shConfig("\(listenerLine); exec sleep 30"))
        runner.start()
        #expect(await waitUntil { runner.state == .running })
        var edited = runner.rule
        edited.mappings = ["0:81"]
        runner.update(rule: edited)
        #expect(runner.log.contains { $0.contains("配置已修改") })
        #expect(await waitUntil { runner.state == .running })
        runner.stop()
    }

    @Test func serveReportsAddressAndPeersWithoutLoggingStatus() async {
        let script = """
        echo '# 🐈 Server listening with saved key "home": tcHOME' >&2
        echo '{"listenAddr":"tcHOME"}'
        echo '# ⚠️ WARNING: anyone with the address can connect' >&2
        echo 'status = {"Peer":{"nodekey:aa":{"PublicKey":"nodekey:aa","CurAddr":"1.2.3.4:1"}}}' >&2
        exec sleep 30
        """
        let rule = TunnelRule(name: "srv", kind: .serve, key: "home", services: ["22"])
        let runner = TunnelRunner(rule: rule, config: shConfig(script))
        var reported: [(String, String?)] = []
        runner.onServerAddress = { _, addr, key in reported.append((addr, key)) }
        runner.start()
        #expect(await waitUntil { runner.state == .running && runner.peers.count == 1 })
        #expect(runner.serverAddress == "tcHOME")
        #expect(runner.serverIdentity == .saved("home"))
        #expect(runner.warnings == ["anyone with the address can connect"])
        #expect(reported.first?.0 == "tcHOME" && reported.first?.1 == "home")
        #expect(!runner.log.contains { $0.contains("status =") })
        runner.stop()
    }

    @Test func serveSetupErrorIsPermanent() async {
        let rule = TunnelRule(name: "srv", kind: .serve, services: ["x"])
        let runner = TunnelRunner(rule: rule, config: shConfig(#"echo 'invalid port or service to serve: "x"' >&2; exit 1"#))
        runner.start()
        #expect(await waitUntil { isFailed(runner.state) })
    }

    @Test func socksReportsProxyURL() async {
        let rule = TunnelRule(name: "s", kind: .socks)
        let runner = TunnelRunner(rule: rule,
            config: shConfig("echo '2026/09/30 10:00:00 SOCKS running at socks5h://127.0.0.1:1080' >&2; exec sleep 30"))
        runner.start()
        #expect(await waitUntil { runner.state == .running })
        #expect(runner.socksAddress == "socks5h://127.0.0.1:1080")
        runner.stop()
    }
}

@Suite struct ProcessRunnerTests {
    @Test func drainsOutputLargerThanPipeBuffer() async {
        // 256 KiB on each stream would deadlock if the pipes were read only after exit.
        let script = "head -c 262144 /dev/zero | tr '\\0' a; head -c 262144 /dev/zero | tr '\\0' b >&2"
        let out = await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                          hardTimeout: 20)
        #expect(out.status == 0)
        #expect(out.stdout.count == 262_144)
        #expect(out.stderr.count == 262_144)
    }

    @Test func lineReaderSplitsAndKeepsUnterminatedTail() async throws {
        let pipe = Pipe()
        let lines = PipeReader.lines(pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("one\r\ntwo\n\nthree".utf8))
        try pipe.fileHandleForWriting.close()
        var got: [String] = []
        for await line in lines { got.append(line) }
        #expect(got == ["one", "two", "", "three"])
    }

    @Test func hardTimeoutKills() async {
        let started = Date()
        let out = await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec sleep 30"],
                                          hardTimeout: 0.3)
        #expect(out.status != 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func cancelledBeforeLaunchNeverRuns() async {
        let marker = tempDir()
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)   // ends early once cancelled
            return await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                           arguments: ["-c", "touch '\(marker.path)'"], hardTimeout: 5)
        }
        task.cancel()
        #expect(await task.value.status == nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func errorSummaryIsLastStderrLine() {
        #expect(ProcessOutput(status: 1, stdout: "", stderr: "usage\n\nboom\n").errorSummary == "boom")
        #expect(ProcessOutput(status: 3, stdout: "", stderr: "").errorSummary == "退出码 3")
    }
}

/// A shell script named `tailcat` that answers the exact argv TailcatCLI should send.
private func fakeTailcat() throws -> (URL, TailcatCLI) {
    let dir = tempDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let exe = dir.appendingPathComponent("tailcat")
    let script = """
    #!/bin/sh
    case "$*" in
      "version") echo v0.7.0 ;;
      "genkey --list") printf 'home\\ndefault\\n' ;;
      "genkey --region=list") printf '  1 nyc New York City\\n  2 sfo San Francisco\\n' >&2 ;;
      "genkey --key=home --fixed-region") echo tcNEWADDR ;;
      "genkey --key=taken") echo 'key "taken" already exists' >&2; exit 1 ;;
      "genkey --client --key=laptop") echo nodekey:abc ;;
      "genkey --delete --key=home") ;;
      "--key=laptop printpub") echo nodekey:abc ;;
      "ping --timeout=5s tcS"|"ping --timeout=10s tcS") echo 'pong in 3.2ms via 10.0.0.1:41641' ;;
      "ping --until-direct --timeout=20s tcS") exit 1 ;;
      "ls -l tcS:docs") printf '%s\\n' '-rw-r--r--            5 Sep  3 14:05 a.txt' 'drwxr-xr-x           64 Sep  3 14:05 sub/' ;;
      "--json perf --time=10s --timeout=10s tcS")
        echo '# path: direct' >&2
        echo '{"path":{"direct":true,"rtt":1000000},"params":{"proto":"tcp","dir":"up","streams":1,"length":0}}' ;;
      *) echo "unexpected: $*" >&2; exit 2 ;;
    esac
    """
    try Data(script.utf8).write(to: exe)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    let path = exe.path
    let locator = BinaryLocator(customPath: { path }, searchDirectories: [], environmentPATH: nil)
    return (dir, TailcatCLI(locator: locator, settings: testSettings()))
}

@Suite struct TailcatCLITests {
    @Test func infoAndCapabilities() async throws {
        let (dir, cli) = try fakeTailcat()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await cli.version() == "v0.7.0")
        let (version, caps) = await cli.capabilities()
        #expect(version == TailcatVersion(0, 7, 0))
        #expect(!caps.perf)
    }

    @Test func keys() async throws {
        let (dir, cli) = try fakeTailcat()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await cli.listKeys().get() == ["default", "home"])
        #expect(try await cli.listRegions().get().map(\.code) == ["nyc", "sfo"])
        #expect(try await cli.generateServerKey(name: "home", region: .nearestNow).get() == "tcNEWADDR")
        #expect(try await cli.generateClientKey(name: "laptop").get() == "nodekey:abc")
        #expect(try await cli.printpub(key: "laptop").get() == "nodekey:abc")
        #expect((try? await cli.deleteKey(name: "home").get()) != nil)
        guard case .failure(let err) = await cli.generateServerKey(name: "taken", region: .auto) else {
            Issue.record("expected failure"); return
        }
        #expect(err.message.contains("already exists"))
        guard case .failure = await cli.generateServerKey(name: "-bad", region: .auto) else {
            Issue.record("invalid name must not reach tailcat"); return
        }
    }

    @Test func pingListAndPerf() async throws {
        let (dir, cli) = try fakeTailcat()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = ClientIdentity(address: "tcS")
        #expect(await cli.ping(id, timeoutSeconds: 5)?.path == .direct(endpoint: "10.0.0.1:41641"))
        let entries = try await cli.list(id, path: "docs").get()
        #expect(entries.map(\.name) == ["a.txt", "sub"])
        #expect(entries[1].isDirectory)
        let report = try await cli.perf(id, options: PerfOptions()).get()
        #expect(report.path.direct && report.params.proto == "tcp")
    }
}

@MainActor
@Suite struct RuleManagerTests {
    private func manager(dir: URL, probe: @escaping @Sendable () -> PingResult? = { healthyPing },
                         script: @escaping @Sendable (TunnelRule) -> String) -> RuleManager {
        let locator = BinaryLocator(customPath: { nil }, searchDirectories: [], environmentPATH: nil,
                                    isExecutable: { _ in false })
        return RuleManager(store: RuleStore(directory: dir), locator: locator, settings: testSettings(),
                           makeConfig: { _ in shConfig(script: script, probe: probe) })
    }

    @Test func failedRemoteSaveKeepsInlineAddresses() throws {
        let dir = tempDir()
        let remotesFile = dir.appendingPathComponent("remotes.json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: remotesFile.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try RuleStore(directory: dir).save([TunnelRule(name: "web", address: "tcWEB", mappings: ["80"])])
        // A locked (uchg) remotes.json reads fine but cannot be replaced.
        try ListStore<Remote>(fileURL: remotesFile).save([])
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: remotesFile.path)

        let m = manager(dir: dir) { _ in "exit 0" }
        m.bootstrap()
        defer { m.shutdown() }
        #expect(m.loadError?.contains("保存失败") == true)
        #expect(m.remotes.isEmpty)
        #expect(m.rules[0].address == "tcWEB" && m.rules[0].remoteID == nil)
        #expect(try RuleStore(directory: dir).load()[0].address == "tcWEB")

        m.add(TunnelRule(name: "db", address: "tcDB", mappings: ["5432"]))
        #expect(m.rules[1].address == "tcDB" && m.rules[1].remoteID == nil)
        #expect(try RuleStore(directory: dir).load().map(\.address) == ["tcWEB", "tcDB"])
    }

    @Test func failedRemoteSaveLeavesNothingToReference() throws {
        let dir = tempDir()
        let remotesFile = dir.appendingPathComponent("remotes.json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: remotesFile.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let m = manager(dir: dir) { _ in "exit 0" }
        m.bootstrap()
        defer { m.shutdown() }
        let box = Remote(name: "box", address: "tcBOX")
        #expect(m.saveRemote(box))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: remotesFile.path)

        // Neither a new remote nor an edit may exist only in memory: a rule picking it up would be
        // saved with its address cleared.
        let nas = Remote(name: "nas", address: "tcNAS")
        #expect(!m.saveRemote(nas))
        var moved = box
        moved.address = "tcMOVED"
        #expect(!m.saveRemote(moved))
        #expect(m.remotes == [box])
        #expect(m.remoteDirectory.remote(id: nas.id) == nil)
        #expect(m.remoteDirectory.remote(id: box.id) == box)

        m.add(TunnelRule(name: "nas", address: "tcNAS", mappings: ["80"]))
        #expect(try RuleStore(directory: dir).load()[0].address == "tcNAS")
        #expect(!m.removeRemote(id: box.id))
        #expect(m.remotes == [box])
    }

    @Test func failedHealthCheckMarksRemoteDown() async {
        final class Switch: @unchecked Sendable { var up = true }
        let remoteUp = Switch()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = manager(dir: dir, probe: { remoteUp.up ? healthyPing : nil }) { _ in "\(listenerLine); exec sleep 30" }
        m.bootstrap()
        defer { m.shutdown() }
        let remote = Remote(name: "box", address: "tcBOX")
        m.saveRemote(remote)
        var rule = TunnelRule(name: "fwd", mappings: ["0:80"], healthCheck: true)
        rule.remoteID = remote.id
        m.add(rule)
        m.runners[0].start()
        #expect(await waitUntil { m.remotePings[remote.id]?.result == healthyPing })

        remoteUp.up = false
        #expect(await waitUntil { m.remotePings[remote.id].map { $0.result == nil } == true })
    }

    @Test func bootstrapMigratesInlineAddressesIntoRemotes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RuleStore(directory: dir).save([TunnelRule(name: "web", address: "tcWEB", key: "k", mappings: ["80"])])

        let m = manager(dir: dir) { _ in "exit 0" }
        m.bootstrap()
        defer { m.shutdown() }
        #expect(m.remotes.count == 1)
        #expect(m.remotes[0].address == "tcWEB" && m.remotes[0].key == "k")
        #expect(m.rules[0].remoteID == m.remotes[0].id && m.rules[0].address.isEmpty)
        #expect(m.remoteDirectory.remote(id: m.remotes[0].id) == m.remotes[0])

        let saved = try RuleStore(directory: dir).load()
        #expect(saved[0].address.isEmpty)
        let remotes = try ListStore<Remote>(fileURL: dir.appendingPathComponent("remotes.json")).load()
        #expect(remotes == m.remotes)
        #expect(!m.removeRemote(id: remotes[0].id))
    }

    @Test func wakeRestartsOnlyClientRules() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = manager(dir: dir) { rule in
            rule.kind == .serve
                ? "echo '# 🐈 Server listening with new address: tcE' >&2; exec sleep 30"
                : "\(listenerLine); exec sleep 30"
        }
        m.bootstrap()
        defer { m.shutdown() }
        m.add(TunnelRule(name: "fwd", address: "tcx", mappings: ["0:80"], healthCheck: false))
        m.add(TunnelRule(name: "srv", kind: .serve, services: ["22"]))
        for r in m.runners { r.start() }
        #expect(await waitUntil { m.runners.allSatisfy { $0.state == .running } })

        m.restartActive(reason: "网络变化")
        let fwd = m.runners.first { $0.rule.kind == .forward }!
        let srv = m.runners.first { $0.rule.kind == .serve }!
        #expect(fwd.log.contains { $0.contains("网络变化") })
        #expect(!srv.log.contains { $0.contains("网络变化") })
        #expect(srv.serverAddress == "tcE")
    }

    @Test func pingRemoteRecordsReachability() async throws {
        let (fake, _) = try fakeTailcat()
        let dir = tempDir()
        defer {
            try? FileManager.default.removeItem(at: fake)
            try? FileManager.default.removeItem(at: dir)
        }
        let exe = fake.appendingPathComponent("tailcat").path
        let m = RuleManager(store: RuleStore(directory: dir),
                            locator: BinaryLocator(customPath: { exe }, searchDirectories: [], environmentPATH: nil),
                            settings: testSettings())
        let remote = Remote(name: "s", address: "tcS")
        m.saveRemote(remote)

        #expect(await m.pingRemote(id: remote.id) != nil)
        let reachable = m.remotePings[remote.id]
        #expect(reachable?.result?.isDirect == true)
        #expect(m.pingingRemotes.isEmpty)

        // Not going direct in time must not mark a reachable remote as down.
        #expect(await m.pingRemote(id: remote.id, untilDirect: true) == nil)
        #expect(m.remotePings[remote.id] == reachable)
    }

    @Test func editingRemoteAddressRestartsItsRules() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = manager(dir: dir) { _ in "\(listenerLine); exec sleep 30" }
        m.bootstrap()
        defer { m.shutdown() }
        let remote = Remote(name: "box", address: "tcOLD")
        m.saveRemote(remote)
        var rule = TunnelRule(name: "fwd", mappings: ["0:80"], healthCheck: false)
        rule.remoteID = remote.id
        m.add(rule)
        m.runners[0].start()
        #expect(await waitUntil { m.runners[0].state == .running })

        var renamed = remote
        renamed.name = "renamed"
        m.saveRemote(renamed)
        #expect(!m.runners[0].log.contains { $0.contains("已修改") })

        // Pings through a rule report the remote's reachability; an address change invalidates it.
        await m.runners[0].runPing()
        #expect(m.remotePings[remote.id]?.result == healthyPing)

        var moved = renamed
        moved.address = "tcNEW"
        m.saveRemote(moved)
        #expect(m.remotePings[remote.id] == nil)
        #expect(m.runners[0].log.contains { $0.contains("远端「renamed」已修改") })
        #expect(m.remoteDirectory.remote(id: remote.id)?.address == "tcNEW")
        #expect(try! ListStore<Remote>(fileURL: dir.appendingPathComponent("remotes.json")).load() == [moved])
    }

    @Test func serverBannerRecordsKeyAddress() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = manager(dir: dir) { _ in #"echo '# 🐈 Server listening with saved key "home": tcHOME' >&2; exec sleep 30"# }
        m.bootstrap()
        defer { m.shutdown() }
        m.recordKey(KeyMeta(name: "home", region: "sfo"))
        m.add(TunnelRule(name: "srv", kind: .serve, key: "home", services: ["22"]))
        m.runners[0].start()
        #expect(await waitUntil { m.keyMeta(name: "home")?.address == "tcHOME" })
        #expect(m.keyMeta(name: "home")?.role == .server)
        #expect(m.keyMeta(name: "home")?.region == "sfo")
    }

    @Test func recvRuleReportsNewFiles() async throws {
        let dir = tempDir()
        let inbox = tempDir()
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: inbox)
        }
        let m = manager(dir: dir) { _ in "exec sleep 30" }
        var received: [URL] = []
        m.onFilesReceived = { _, urls in received.append(contentsOf: urls) }
        m.bootstrap()
        defer { m.shutdown() }
        m.add(TunnelRule(name: "in", kind: .recv, recvDir: inbox.path))
        let id = m.runners[0].id
        m.runners[0].start()
        try await Task.sleep(nanoseconds: 100_000_000)
        try Data("hi".utf8).write(to: inbox.appendingPathComponent("hello.txt"))
        #expect(await waitUntil { m.inbox[id] == ["hello.txt"] })
        #expect(received.map(\.lastPathComponent) == ["hello.txt"])
        m.clearInbox(id: id)
        #expect(m.inbox[id] == nil)
    }
}
