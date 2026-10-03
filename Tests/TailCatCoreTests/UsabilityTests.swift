import Foundation
import Testing
@testable import TailCatCore

@Suite struct UsabilityTests {
    @Test(arguments: ["port", "address", "key", "id"])
    func fileBrowserResetsWhenEndpointChanges(_ field: String) throws {
        var remote = Remote(name: "Home", address: "tcEXAMPLE")
        let entries = FileListing.parse("-rw-r--r-- 12 Oct 3 09:00 old-service.txt")
        var browser = FileBrowserState(remote: remote, path: "documents", entries: entries)
        let pendingID = browser.beginListing()
        let pending = try #require(pendingID)
        switch field {
        case "port": remote.filePort = 2222
        case "address": remote.address = "tcOTHER"
        case "key": remote.key = "other-client"
        default: remote.id = UUID()
        }
        let changed = browser.updateRemote(remote)
        #expect(changed)
        #expect(browser.path == "." && browser.entries == nil && !browser.loading && browser.error == nil)
        browser.finishListing(.success(entries), path: "documents/old", requestID: pending)
        browser.finishListing(.failure(CLIError("old endpoint failed")), path: "documents/old", requestID: pending)
        #expect(browser.path == "." && browser.entries == nil && !browser.loading && browser.error == nil)
        if field == "port" {
            let blocked = browser.beginListing()
            #expect(blocked == nil)
        }
    }

    @Test func fileBrowserRejectsRequestsFromBeforePortRoundTripAndCancellation() throws {
        var remote = Remote(name: "Home", address: "tcEXAMPLE")
        var browser = FileBrowserState(remote: remote)
        let oldID = browser.beginListing()
        let old = try #require(oldID)
        remote.filePort = 2222
        browser.updateRemote(remote)
        browser.path = "custom-port-folder"
        let blocked = browser.beginListing()
        #expect(blocked == nil)
        remote.filePort = 22
        browser.updateRemote(remote)
        #expect(browser.path == ".")
        let currentID = browser.beginListing()
        let current = try #require(currentID)
        browser.finishListing(.success([]), path: "old", requestID: old)
        #expect(browser.path == "." && browser.entries == nil && browser.loading)
        browser.finishListing(.success([]), path: "current", requestID: current)
        #expect(browser.path == "current" && browser.entries == [] && !browser.loading)

        let supersededID = browser.beginListing()
        let superseded = try #require(supersededID)
        let latestID = browser.beginListing()
        let latest = try #require(latestID)
        browser.finishListing(.failure(CLIError("late failure")), path: "old", requestID: superseded)
        #expect(browser.loading && browser.error == nil)
        browser.cancelListing()
        browser.finishListing(.success([]), path: "cancelled", requestID: latest)
        #expect(browser.path == "current" && !browser.loading && browser.error == nil)
    }

    @Test func fileBrowserKeepsDirectoryWhenOtherRemoteSettingsChange() throws {
        var remote = Remote(name: "Home", address: "tcEXAMPLE")
        var browser = FileBrowserState(remote: remote, path: "documents", entries: [])
        let pendingID = browser.beginListing()
        let pending = try #require(pendingID)
        remote.name = "Renamed"
        remote.webPort = 8080
        remote.sshPort = "2222"
        remote.sshUser = "alice"
        let changed = browser.updateRemote(remote)
        #expect(!changed)
        #expect(browser.path == "documents" && browser.entries == [] && browser.loading)
        browser.finishListing(.success([]), path: "documents/reports", requestID: pending)
        #expect(browser.path == "documents/reports" && !browser.loading)
    }

    @Test func oldRemoteDefaultsAndPortRoundTrip() throws {
        let old = try JSONDecoder().decode(Remote.self, from: Data(#"{"name":"Home","address":"tcEXAMPLE"}"#.utf8))
        #expect(old.sshPort.isEmpty && old.webPort == 80 && old.filePort == 22)
        var remote = old
        remote.sshPort = "192.168.1.10:2222"
        remote.webPort = 8080
        remote.filePort = 2222
        #expect(try JSONDecoder().decode(Remote.self, from: JSONEncoder().encode(remote)) == remote)
        #expect(remote.validate().isEmpty)
        remote.filePort = 0
        #expect(remote.validate().contains(.invalidServicePort))
        for port in ["", "22", "65535", "192.168.1.10", "192.168.1.10:2222", "::1", "[::1]:2222"] {
            #expect(SSHLauncher.isValidPort(port))
        }
        for port in ["0", "65536", ":", "192.168.1.999:22", "[::1]:0", "-p22", "22\n", "::1\0ignored"] {
            #expect(!SSHLauncher.isValidPort(port))
        }
        #expect(TailcatCLI.copyArguments(identity: old.identity, sources: ["/tmp/report.txt"], target: "tcEXAMPLE:",
                                        recursive: false, preserve: true, port: 2222, settings: testSettings())
                == ["cp", "-p", "-P", "2222", "/tmp/report.txt", "tcEXAMPLE:"])
    }

    @Test func probePreservesFailureAndRejectsUnparseableOutput() async throws {
        let (dir, cli) = try fixtureCLI("echo 'lookup home.example.com: no such host' >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await cli.probe(ClientIdentity(address: "tcEXAMPLE"))
        guard case .failure(let error) = outcome else { Issue.record("Expected DNS error"); return }
        #expect(error.message.contains("no such host"))
        #expect(error.recoverySuggestion.contains("TXT"))
        try Data("#!/bin/sh\necho unexpected\n".utf8).write(to: dir.appendingPathComponent("tailcat"))
        guard case .failure(let parseError) = await cli.probe(ClientIdentity(address: "tcEXAMPLE")) else {
            Issue.record("Expected parse failure"); return
        }
        #expect(parseError.message.contains("无法解析"))
        let missing = TailcatCLI(locator: BinaryLocator(searchDirectories: [], environmentPATH: nil, isExecutable: { _ in false }), settings: testSettings())
        guard case .failure(let missingError) = await missing.probe(ClientIdentity(address: "tcEXAMPLE")) else {
            Issue.record("Expected missing binary"); return
        }
        #expect(missingError.needsBinaryCheck)
    }

    @Test @MainActor func transferCompletionCancellationRetryAndClear() async throws {
        let (dir, cli) = try fixtureCLI("exec sleep 30")
        defer { try? FileManager.default.removeItem(at: dir) }
        let transfers = TransferManager(cli: cli)
        let remote = Remote(name: "Home", address: "tcEXAMPLE", filePort: 2222)
        let id = transfers.start(remote: remote, operation: .upload(files: [dir.appendingPathComponent("report.txt")], path: ""))
        #expect(transfers.activeCount == 1)
        transfers.clearFinished()
        #expect(transfers.items.count == 1)
        transfers.cancel(id)
        try await waitUntil { transfers.activeCount == 0 }
        #expect(transfers.items.first?.state == .cancelled)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: dir.appendingPathComponent("tailcat"))
        transfers.retry(id)
        try await waitUntil { transfers.activeCount == 0 }
        #expect(transfers.items.first?.state == .succeeded)
        #expect(transfers.items.first?.remote.filePort == 2222)
        #expect(transfers.items.count == 2)
        transfers.clearFinished()
        #expect(transfers.items.isEmpty)
        try Data("#!/bin/sh\necho 'denied tcABCDEFGHIJKLMNOPQRSTUVWX' >&2; exit 1\n".utf8).write(to: dir.appendingPathComponent("tailcat"))
        transfers.start(remote: remote, operation: .download(path: "report.txt", isDirectory: false, destination: dir))
        try await waitUntil { transfers.activeCount == 0 }
        guard case .failed(let message) = transfers.items.first?.state else { Issue.record("Expected failure"); return }
        #expect(!message.contains("tcABCDEFGHIJKLMNOPQRSTUVWX"))
        #expect(transfers.items.first?.downloadedURL == nil)
    }

    @Test @MainActor func websiteRuleUsesSavedPortAndReusesIt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = RuleManager(store: RuleStore(directory: dir), settings: testSettings())
        let remote = Remote(name: "Home", address: "tcEXAMPLE", webPort: 8080)
        #expect(manager.saveRemote(remote))
        let first = try #require(manager.websiteRule(for: remote.id))
        #expect(first.rule.mappings == ["0:8080"])
        #expect(manager.websiteRule(for: remote.id)?.id == first.id)
    }
}

private func fixtureCLI(_ body: String) throws -> (URL, TailcatCLI) {
    let dir = tempDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let exe = dir.appendingPathComponent("tailcat")
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: exe)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exe.path)
    let path = exe.path
    return (dir, TailcatCLI(locator: BinaryLocator(customPath: { path }, searchDirectories: [], environmentPATH: nil), settings: testSettings()))
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(condition())
}

@Suite struct ConfigurationImportTests {
    @Test @MainActor func exportMergePreservesExistingAndNeverAutostarts() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exportDir = dir.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exportDir.path)
        let remote = Remote(name: "Home", address: "tcEXAMPLE", webPort: 8080)
        let rule = TunnelRule(name: "Web", remoteID: remote.id, mappings: ["0:8080"], autoStart: true)
        let contact = Contact(name: "Alice", publicKey: "nodekey:" + String(repeating: "a", count: 64))
        let backup = ConfigurationBackup(rules: [rule], remotes: [remote], contacts: [contact])
        let url = exportDir.appendingPathComponent("backup.json")
        try backup.write(to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: exportDir.path)[.posixPermissions] as? Int == 0o755)
        let read = try ConfigurationBackup.read(from: url)
        let manager = RuleManager(store: RuleStore(directory: dir.appendingPathComponent("data")), settings: testSettings())
        var existing = remote
        existing.address = "tcOTHER"
        #expect(manager.saveRemote(existing))
        let plan = try manager.previewImport(read)
        #expect(plan.remotes.first?.id != existing.id)
        #expect(plan.rules.first?.remoteID == plan.remotes.first?.id)
        #expect(plan.rules.first?.autoStart == false)
        #expect(manager.importConfiguration(plan))
        #expect(manager.remote(id: existing.id)?.address == "tcOTHER")
        #expect(manager.runners.allSatisfy { $0.state == .stopped })
        let repeated = try manager.previewImport(read)
        #expect(repeated.rules.isEmpty && repeated.remotes.isEmpty && repeated.contacts.isEmpty)
        #expect(repeated.skipped == 3)
    }

    @Test @MainActor func failedImportKeepsDependenciesAndCanBeRetried() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let remote = Remote(name: "Home", address: "tcEXAMPLE")
        let backup = ConfigurationBackup(rules: [TunnelRule(name: "Web", remoteID: remote.id, mappings: ["8080"])], remotes: [remote], contacts: [])
        let manager = RuleManager(store: RuleStore(directory: dir), settings: testSettings())
        let blocker = dir.appendingPathComponent("rules.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        let plan = try manager.previewImport(backup)
        #expect(!manager.importConfiguration(plan))
        #expect(manager.rules.isEmpty)
        #expect(manager.remotes.count == 1)
        try FileManager.default.removeItem(at: blocker)
        #expect(manager.importConfiguration(try manager.previewImport(backup)))
        #expect(manager.rules.count == 1 && manager.remotes.count == 1)
        #expect(manager.runners.first?.state == .stopped)
    }

    @Test func rejectsInvalidReferencesAndFutureVersions() throws {
        let missing = ConfigurationBackup(rules: [TunnelRule(name: "Web", remoteID: UUID(), mappings: ["80"])], remotes: [], contacts: [])
        #expect(throws: CLIError.self) { try missing.validate() }
        var future = ConfigurationBackup(rules: [], remotes: [], contacts: [])
        future.version = 999
        #expect(throws: RuleStoreError.self) { try future.validate() }
        let remote = Remote(name: "Home", address: "tcEXAMPLE")
        #expect(throws: CLIError.self) { try ConfigurationBackup(rules: [], remotes: [remote, remote], contacts: []).validate() }
    }

    @Test func terminalCommandPreservesArgumentsAndRejectsOptionsAsProgram() async throws {
        let remote = Remote(name: "Home", address: "tcEXAMPLE", key: "laptop", sshUser: "alice", sshPort: "2222")
        let command = ["printf", "%s", "hello ' $(ignored); world"]
        let args = try SSHLauncher.commandArguments(remote: remote, mode: .ssh, command: command, settings: testSettings()).get()
        #expect(args == ["--key=laptop", "ssh", "-p", "2222", "alice@tcEXAMPLE", command.map(ShellQuote.quote).joined(separator: " ")])
        // Exercise the shell boundary OpenSSH uses, without connecting to any remote.
        let output = await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", try #require(args.last)], hardTimeout: 3)
        #expect(output.status == 0)
        #expect(output.stdout == command[2])
        let socks = try SSHLauncher.commandArguments(remote: remote, mode: .socks, command: ["curl", "http://server.tailcat:8080/"], settings: testSettings()).get()
        #expect(socks == ["--key=laptop", "socks", "tcEXAMPLE", "curl", "http://server.tailcat:8080/"])
        #expect(throws: CLIError.self) { try SSHLauncher.commandArguments(remote: remote, mode: .socks, command: ["--help"]).get() }
        #expect(throws: CLIError.self) { try SSHLauncher.commandArguments(remote: remote, mode: .ssh, command: ["echo\0oops"]).get() }
    }
}
