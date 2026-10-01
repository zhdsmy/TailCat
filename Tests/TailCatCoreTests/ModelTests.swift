import Foundation
import Testing
@testable import TailCatCore

/// Isolated settings so tests do not see the developer's --verbose / --derpmap-url.
func testSettings() -> AppSettings {
    AppSettings(defaults: UserDefaults(suiteName: "tailcat.tests.\(UUID().uuidString)")!)
}

let sampleKey = "nodekey:" + String(repeating: "ab", count: 32)

@Suite struct SettingsMigrationTests {
    @Test func copiesMissingKeysOnce() {
        let names = ["tailcat.tests.old.\(UUID().uuidString)", "tailcat.tests.new.\(UUID().uuidString)"]
        defer { names.forEach(UserDefaults.standard.removePersistentDomain(forName:)) }
        let old = UserDefaults(suiteName: names[0])!, new = UserDefaults(suiteName: names[1])!
        old.set("/opt/tailcat", forKey: AppSettings.Key.customBinaryPath)
        old.set(false, forKey: AppSettings.Key.notificationsEnabled)
        old.set(true, forKey: AppSettings.Key.verbose)
        old.set("unrelated", forKey: "someOtherKey")
        new.set(false, forKey: AppSettings.Key.verbose)

        AppSettings.migrateLegacyDefaults(from: old, to: new)
        let settings = AppSettings(defaults: new)
        #expect(settings.customBinaryPath == "/opt/tailcat")
        #expect(settings.notificationsEnabled == false)
        #expect(settings.verbose == false)
        #expect(new.object(forKey: "someOtherKey") == nil)

        // Later changes in the old domain (e.g. the old build still running) are not re-applied.
        old.set("https://derp.example.com/map.json", forKey: AppSettings.Key.derpmapURL)
        AppSettings.migrateLegacyDefaults(from: old, to: new)
        #expect(settings.derpmapURL == "")
    }
}

@Suite struct MappingTests {
    @Test func parsesForms() {
        #expect(MappingSpec.parse("8080") == MappingSpec(localPort: 8080, remoteHost: nil, remotePort: 8080))
        #expect(MappingSpec.parse("2222:22") == MappingSpec(localPort: 2222, remoteHost: nil, remotePort: 22))
        #expect(MappingSpec.parse("0:8080") == MappingSpec(localPort: 0, remoteHost: nil, remotePort: 8080))
        #expect(MappingSpec.parse("3306:192.168.1.10:3306")
                == MappingSpec(localPort: 3306, remoteHost: "192.168.1.10", remotePort: 3306))
    }

    @Test(arguments: ["", "0", "65536", "abc", "1:2:3:4", "80:", ":80", "1:999.1.1.1:2", "1:host:2", "-1", "8 0"])
    func rejectsBad(_ raw: String) {
        #expect(MappingSpec.parse(raw) == nil)
    }

    @Test func displayLabels() {
        #expect(MappingSpec.parse("2222:22")?.displayLabel == "本机 2222 → 远端 22")
        #expect(MappingSpec.parse("0:8080")?.displayLabel == "本机 自动分配端口 → 远端 8080")
        #expect(MappingSpec.parse("3306:192.168.1.10:3306")?.displayLabel == "本机 3306 → 192.168.1.10:3306（经远端）")
        #expect(ListenerInfo(host: "127.0.0.1", port: 2222, target: "22").targetLabel == "远端 22")
        #expect(ListenerInfo(host: "127.0.0.1", port: 2222, target: "localhost:22").targetLabel == "远端 22")
        #expect(ListenerInfo(host: "127.0.0.1", port: 2222, target: "[::1]:22").targetLabel == "远端 22")
        #expect(ListenerInfo(host: "127.0.0.1", port: 1, target: "10.0.0.1:80").targetLabel == "10.0.0.1:80（经远端）")
    }
}

@Suite struct ServeItemTests {
    @Test(arguments: ["22", "ssh", "no-auth-ssh", "files", "exec", "exit-node", "all", "perf",
                      "8000-8999", "8080:80", "5555:192.168.1.10:5555", "5555:[fd7a::1]:5555"])
    func accepts(_ item: String) {
        #expect(ServeItem.isValid(item))
    }

    @Test(arguments: ["", "0", "x", "9-1", "80:", "80:host:1", "--allow=x", "5555:[zz]:1", "1:2:3:4"])
    func rejects(_ item: String) {
        #expect(!ServeItem.isValid(item))
    }

    @Test func servedPort() {
        #expect(ServeItem.servedPort("8080:80") == 8080)
        #expect(ServeItem.servedPort("8000-8999") == 8000)
        #expect(ServeItem.servedPort("ssh") == nil)
    }
}

@Suite struct ForwardRuleTests {
    private func valid() -> TunnelRule {
        TunnelRule(name: "ssh", address: "tcabc", mappings: ["2222:22"])
    }

    @Test func validRulePasses() {
        #expect(valid().validate().isEmpty)
    }

    @Test func reportsEachProblem() {
        var r = valid()
        r.name = " "; r.address = "-x"; r.mappings = ["bogus"]; r.bind = "a b"; r.key = "-k"
        let issues = r.validate()
        #expect(issues.contains(.emptyName))
        #expect(issues.contains(.invalidAddress))
        #expect(issues.contains(.invalidMapping("bogus")))
        #expect(issues.contains(.invalidBind))
        #expect(issues.contains(.invalidKey))
        var none = valid(); none.mappings = []
        #expect(none.validate().contains(.noMappings))
    }

    @Test func remoteSuppliesAddressAndKey() {
        let settings = testSettings()
        let remote = Remote(name: "box", address: "tcREMOTE", key: "work")
        var r = valid()
        r.address = ""; r.remoteID = remote.id
        #expect(r.validate().isEmpty)
        #expect(r.arguments(settings: settings, remote: remote)
                == ["--key=work", "forward", "--bind=127.0.0.1", "tcREMOTE", "2222:22"])
        // A remote with another id is ignored rather than silently used.
        #expect(r.identity(remote: Remote(name: "other", address: "tcOTHER")).address == "")
    }

    @Test func globalFlagsPrecedeSubcommand() {
        let settings = testSettings()
        var r = valid()
        r.key = "work"
        #expect(r.arguments(settings: settings) == ["--key=work", "forward", "--bind=127.0.0.1", "tcabc", "2222:22"])
        r.key = ""
        settings.verbose = true
        settings.derpmapURL = "https://derp.example/map.json"
        #expect(r.arguments(settings: settings)
                == ["--verbose", "--derpmap-url=https://derp.example/map.json", "forward", "--bind=127.0.0.1",
                    "tcabc", "2222:22"])
    }

    @Test func pingArguments() {
        let id = ClientIdentity(address: "tcabc")
        let settings = testSettings()
        #expect(id.pingArguments(timeoutSeconds: 10, settings: settings) == ["ping", "--timeout=10s", "tcabc"])
        #expect(id.pingArguments(timeoutSeconds: 20, untilDirect: true, settings: settings)
                == ["ping", "--until-direct", "--timeout=20s", "tcabc"])
    }

    @Test func cliCommandQuotes() {
        let settings = testSettings()
        #expect(valid().cliCommand(settings: settings) == "tailcat forward --bind=127.0.0.1 tcabc 2222:22")
        var s = TunnelRule(name: "x", kind: .serve, services: ["exec"], execArgs: ["sh", "-c", "echo it's"])
        s.allow = sampleKey
        #expect(s.cliCommand(settings: settings)
                == "tailcat serve --allow=\(sampleKey) exec -- sh -c 'echo it'\\''s'")
    }

    @Test func decodingV1RuleDefaultsToForward() throws {
        let rule = try JSONDecoder().decode(TunnelRule.self, from: Data(#"{"name":"x","address":"tc1"}"#.utf8))
        #expect(rule.kind == .forward)
        #expect(rule.bind == "127.0.0.1")
        #expect(rule.autoRestart && rule.healthCheck && !rule.autoStart)
        #expect(rule.socksListen == "127.0.0.1:1080")
    }
}

@Suite struct ServeRuleTests {
    private func serve(_ services: [String] = ["22"]) -> TunnelRule {
        TunnelRule(name: "srv", kind: .serve, services: services)
    }

    @Test func buildsArguments() {
        let settings = testSettings()
        var r = serve(["22", "8080:80, 5555:10.0.0.2:5555", "ssh"])
        r.key = "home"
        r.allow = "\(sampleKey), none"
        r.sshAuthorizedKeys = "me@github, /Users/me/.ssh/authorized_keys"
        r.filesDir = "/Users/me/Share"
        r.filesMode = .woPlus
        r.fullAddress = true
        #expect(r.validate().isEmpty)
        #expect(r.arguments(settings: settings) == [
            "--key=home", "--json", "serve", "--full-address", "--allow=\(sampleKey),none",
            "--ssh-authorized-keys=me@github, /Users/me/.ssh/authorized_keys", "--files=/Users/me/Share:wo+",
            "22", "8080:80", "5555:10.0.0.2:5555", "ssh",
        ])
    }

    @Test func execArgvGoesAfterDoubleDash() {
        var r = serve(["exec"])
        r.execArgs = ["/usr/bin/say", "", "hello world"]
        #expect(r.validate().isEmpty)
        #expect(r.arguments(settings: testSettings()) == ["--json", "serve", "exec", "--", "/usr/bin/say", "hello world"])
        r.execArgs = []
        #expect(r.validate().contains(.invalidExec))
    }

    @Test func filesDirectoryAloneIsAService() {
        var r = serve([])
        #expect(r.validate().contains(.noServices))
        r.filesDir = "/tmp/share"
        #expect(r.validate().isEmpty)
        r.filesDir = "relative"
        #expect(r.validate().contains(.invalidDirectory))
        var named = serve(["files"])
        #expect(named.validate().contains(.filesNeedsDirectory))
        named.filesDir = "/tmp"
        #expect(named.validate().isEmpty)
    }

    @Test func validationRules() {
        #expect(serve(["ssh"]).validate().contains(.sshNeedsAuthorizedKeys))
        #expect(serve(["bogus"]).validate().contains(.invalidService("bogus")))
        var r = serve()
        r.allow = "nodekey:short"
        #expect(r.validate().contains(.invalidAllow("nodekey:short")))
        r.allow = ""
        r.sshAuthorizedKeys = "-x"
        #expect(r.validate().contains(.invalidAuthorizedKeys))
        // Forms tailcat would read as file paths and fail on.
        var ssh = serve(["ssh"])
        ssh.sshAuthorizedKeys = "me@github, github:me,https://github.com/me.keys"
        #expect(ssh.validate() == [.unsupportedKeySource("github:me"), .unsupportedKeySource("https://github.com/me.keys")])
        ssh.services = ["ssh", "no-auth-ssh"]
        ssh.sshAuthorizedKeys = "me@github"
        #expect(ssh.validate() == [.sshConflict])
    }

    @Test func publicAddressNeedsAllowOrKeyAuthenticatedSSHOnly() {
        var ssh = serve(["ssh"])
        ssh.sshAuthorizedKeys = "me@github"
        #expect(ssh.authenticatesEveryClient)
        // A plain port 22 reaches the local sshd, which may take passwords.
        for extra in ["22", "8080", "no-auth-ssh", "exit-node", "all"] {
            var mixed = ssh
            mixed.services = ["ssh", extra]
            #expect(!mixed.authenticatesEveryClient, "\(extra)")
        }
        var files = ssh
        files.filesDir = "/tmp"
        #expect(!files.authenticatesEveryClient)
        var allowed = serve(["22", "8080"])
        allowed.allow = sampleKey
        #expect(allowed.authenticatesEveryClient)
        #expect(!serve(["ssh"]).authenticatesEveryClient)
    }

    @Test func allowWarningForRiskyServices() {
        #expect(!serve(["22"]).needsAllowWarning)
        #expect(serve(["no-auth-ssh"]).needsAllowWarning)
        #expect(serve(["exit-node"]).needsAllowWarning)
        #expect(serve(["all"]).needsAllowWarning)
        var exec = serve([]); exec.execArgs = ["date"]
        #expect(exec.needsAllowWarning)
        // With ssh, the command is a ForceCommand behind authorized keys.
        var forced = serve(["ssh"]); forced.execArgs = ["date"]
        #expect(!forced.needsAllowWarning)
        var allowed = serve(["no-auth-ssh"]); allowed.allow = sampleKey
        #expect(!allowed.needsAllowWarning)
    }

    @Test func ephemeralIdentity() {
        var r = serve()
        #expect(r.mayBeEphemeralServer && !r.isEphemeralServer)
        r.key = "new"
        #expect(r.isEphemeralServer)
        r.key = "home"
        #expect(!r.mayBeEphemeralServer)
    }

    @Test func peerCommands() {
        var r = serve(["8080:80", "ssh"])
        r.sshAuthorizedKeys = "me@github"
        let cmds = r.peerCommands(serverAddress: "tcS")
        #expect(cmds.contains("tailcat forward tcS 8080"))
        #expect(cmds.contains("tailcat ssh tcS"))
        // ls has no SSH key to offer a key-authenticated server; scp does.
        #expect(!cmds.contains("tailcat ls -l tcS"))
        #expect(cmds.contains("tailcat cp tcS:<文件> ."))
        #expect(cmds.last == "tailcat ping tcS")
        #expect(serve(["no-auth-ssh"]).peerCommands(serverAddress: "tcS").contains("tailcat ls -l tcS"))
    }
}

@Suite struct OtherKindTests {
    @Test func recvArguments() {
        var r = TunnelRule(name: "in", kind: .recv, recvDir: "/Users/me/Inbox", acceptDirs: true)
        #expect(r.validate().isEmpty)
        #expect(r.arguments(settings: testSettings()) == ["--json", "recv", "--accept-dirs", "/Users/me/Inbox"])
        r.recvDir = ""
        #expect(r.validate().contains(.invalidDirectory))
        #expect(!r.kind.isClient)
    }

    @Test func socksArguments() {
        let settings = testSettings()
        var r = TunnelRule(name: "s", kind: .socks)
        #expect(r.validate().isEmpty)
        #expect(r.arguments(settings: settings) == ["socks", "--listen=127.0.0.1:1080"])
        let remote = Remote(name: "exit", address: "tcEXIT", key: "laptop")
        r.remoteID = remote.id
        #expect(r.arguments(settings: settings, remote: remote)
                == ["--key=laptop", "socks", "--listen=127.0.0.1:1080", "tcEXIT"])
        r.socksListen = "-bad"
        #expect(r.validate().contains(.invalidListen))
        #expect(r.kind.isClient)
    }
}

@Suite struct RemoteTests {
    @Test func validation() {
        #expect(Remote(name: "a", address: "tcX").validate().isEmpty)
        let bad = Remote(name: "", address: "-x", key: "a b", sshUser: "-root")
        #expect(bad.validate() == [.emptyName, .invalidAddress, .invalidKey, .invalidUser])
    }

    @Test func migrationMovesInlineAddressesAndDedupes() {
        let a = TunnelRule(name: "web", address: "tcSAME", key: "k", mappings: ["80"])
        let b = TunnelRule(name: "db", address: "tcSAME", key: "k", mappings: ["5432"])
        let c = TunnelRule(name: "other", address: "tcOTHER", mappings: ["22"])
        let srv = TunnelRule(name: "srv", kind: .serve, key: "home", services: ["22"])
        let result = RemoteMigration.migrate(rules: [a, b, c, srv], remotes: [])
        #expect(result.changed)
        #expect(result.remotes.count == 2)
        #expect(result.rules[0].remoteID == result.rules[1].remoteID)
        #expect(result.rules[0].address.isEmpty && result.rules[0].key.isEmpty)
        #expect(result.remotes.first { $0.id == result.rules[0].remoteID }?.key == "k")
        #expect(result.rules[3] == srv)

        let again = RemoteMigration.migrate(rules: result.rules, remotes: result.remotes)
        #expect(!again.changed)
    }

    @Test func migrationReusesExistingRemoteAndDropsDanglingSocksReference() {
        let existing = Remote(name: "box", address: "tcBOX")
        let inline = TunnelRule(name: "x", address: "tcBOX", mappings: ["22"])
        var socks = TunnelRule(name: "s", kind: .socks)
        socks.remoteID = UUID()
        let result = RemoteMigration.migrate(rules: [inline, socks], remotes: [existing])
        #expect(result.remotes == [existing])
        #expect(result.rules[0].remoteID == existing.id)
        #expect(result.rules[1].remoteID == nil)
    }
}

@Suite struct ContactTests {
    @Test func publicKeyFormat() {
        #expect(Contact.isValidPublicKey(sampleKey))
        #expect(!Contact.isValidPublicKey("nodekey:abc"))
        #expect(!Contact.isValidPublicKey(String(sampleKey.dropFirst(8))))
        #expect(!Contact.isValidPublicKey("nodekey:" + String(repeating: "zz", count: 32)))
        #expect(Contact(name: "me", publicKey: sampleKey).isValid)
        #expect(TunnelRule.isValidAllowEntry("none"))
    }

    @Test func keyRoleHeuristic() {
        #expect(KeyMeta(name: "client-default").effectiveRole == .client)
        #expect(KeyMeta(name: "default").effectiveRole == .server)
        #expect(KeyMeta(name: "mystery").effectiveRole == nil)
        #expect(KeyMeta(name: "client-x", role: .server).effectiveRole == .server)
    }
}

@Suite struct BackoffTests {
    @Test func doublesThenCaps() {
        let p = BackoffPolicy(base: 1, cap: 60)
        #expect((1...8).map { p.delay(forAttempt: $0) } == [1, 2, 4, 8, 16, 32, 60, 60])
        #expect(p.delay(forAttempt: 500) == 60)
    }
}

@Suite struct LocatorTests {
    @Test func prefersCustomThenSearchDirs() {
        let existing: Set<String> = ["/custom/tailcat", "/opt/homebrew/bin/tailcat", "/usr/bin/tailcat"]
        func make(custom: String?) -> BinaryLocator {
            BinaryLocator(customPath: { custom }, searchDirectories: ["/opt/homebrew/bin"],
                          environmentPATH: "/usr/bin", isExecutable: { existing.contains($0) })
        }
        #expect(make(custom: "/custom/tailcat").locate()?.path == "/custom/tailcat")
        #expect(make(custom: nil).locate()?.path == "/opt/homebrew/bin/tailcat")
        #expect(make(custom: "/missing").locate()?.path == "/opt/homebrew/bin/tailcat")
        let none = BinaryLocator(customPath: { nil }, searchDirectories: [], environmentPATH: nil,
                                 isExecutable: { _ in false })
        #expect(none.locate() == nil)
    }
}

func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("tailcat-test-\(UUID().uuidString)")
}

@Suite struct StoreTests {
    @Test func roundTripsWithRestrictedPermissions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RuleStore(directory: dir)
        #expect(try store.load().isEmpty)

        let rules = [TunnelRule(name: "a", address: "tc1", mappings: ["1:2"]),
                     TunnelRule(name: "b", kind: .serve, services: ["22"], autoStart: true)]
        try store.save(rules)
        try store.save(rules)   // second save exercises the replace path
        #expect(try store.load() == rules)
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(raw.contains(#""version" : 2"#))

        let file = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func loadsVersion1File() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RuleStore(directory: dir)
        let v1 = #"{"version":1,"rules":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"old","address":"tcOLD","key":"","mappings":["22"],"bind":"127.0.0.1","openBrowser":false,"autoRestart":true,"healthCheck":true,"autoStart":false}]}"#
        try Data(v1.utf8).write(to: store.fileURL)
        let rules = try store.load()
        #expect(rules.count == 1)
        #expect(rules[0].kind == .forward)
        #expect(rules[0].address == "tcOLD")
    }

    @Test func corruptFileIsBackedUpNotOverwritten() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RuleStore(directory: dir)
        try Data("not json".utf8).write(to: store.fileURL)

        #expect(throws: RuleStoreError.self) { try store.load() }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("rules.corrupt-") })
    }

    @Test func listStoreRoundTripsDates() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ListStore<KeyMeta>(fileURL: dir.appendingPathComponent("key-meta.json"))
        #expect(try store.load().isEmpty)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metas = [KeyMeta(name: "home", role: .server, address: "tcHOME", updatedAt: date)]
        try store.save(metas)
        #expect(try store.load() == metas)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite struct PIDTrackerTests {
    @Test func reapsOnlyProcessesThatLookLikeTailcat() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = PIDTracker(directory: dir)
        tracker.save(["a": 111, "b": 222])
        nonisolated(unsafe) var signalled: [Int32] = []
        // Real kill() is avoided by only "reaping" pids the predicate rejects.
        tracker.reapOrphans(isTailcat: { signalled.append($0); return false })
        #expect(Set(signalled) == [111, 222])
        #expect(tracker.load().isEmpty)
    }
}
