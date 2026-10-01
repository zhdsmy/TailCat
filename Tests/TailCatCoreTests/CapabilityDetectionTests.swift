import Foundation
import Testing
@testable import TailCatCore

/// Gate the older binary's help probe so assertions do not depend on subprocess timing.
private func writeTailcat(to url: URL, version: String, gatedProbe: Bool = false) throws {
    let script = """
    #!/bin/sh
    case "$*" in
      version) echo \(version) ;;
      "genkey --list") ;;
      "perf --help")
        \(gatedProbe ? "touch \"$0.started\"; while [ ! -f \"$0.release\" ]; do sleep 0.02; done" : ":")
        exit 1 ;;
      *) exit 2 ;;
    esac
    """
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@MainActor
@Suite struct CapabilityDetectionTests {
    @Test func pendingDetectionAndBinaryRefresh() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let modern = dir.appendingPathComponent("modern"), older = dir.appendingPathComponent("older")
        try writeTailcat(to: modern, version: "v0.8.0")
        try writeTailcat(to: older, version: "v0.7.0", gatedProbe: true)
        let settings = testSettings()
        settings.customBinaryPath = modern.path
        let manager = RuleManager(store: RuleStore(directory: dir.appendingPathComponent("data")),
            locator: BinaryLocator(customPath: { settings.customBinaryPath }, searchDirectories: [], environmentPATH: nil),
            settings: settings)
        let rule = TunnelRule(name: "网页", kind: .serve, services: ["8080:80"])
        #expect(manager.capabilities == nil)
        #expect(manager.validateForSave(rule) == [.capabilitiesPending])
        #expect(manager.validateForSave(TunnelRule(name: "连接", address: "tcEXAMPLE", mappings: ["0:80"])).isEmpty)

        await manager.refreshTailcatInfo()
        #expect(manager.capabilities?.serveMappings == true)
        #expect(manager.validateForSave(rule).isEmpty)

        settings.customBinaryPath = older.path
        let refresh = Task { await manager.refreshTailcatInfo() }
        #expect(await waitUntil { FileManager.default.fileExists(atPath: older.path + ".started") })
        #expect(manager.capabilities == nil)
        #expect(manager.validateForSave(rule) == [.capabilitiesPending])
        try Data().write(to: older.appendingPathExtension("release"))
        await refresh.value
        #expect(manager.capabilities?.serveMappings == false)
        #expect(manager.validateForSave(rule) == [.serveMappingUnsupported("8080:80")])
    }

    @Test func olderProbeCannotReplaceLatestResult() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let modern = dir.appendingPathComponent("modern"), older = dir.appendingPathComponent("older")
        try writeTailcat(to: modern, version: "v0.8.0")
        try writeTailcat(to: older, version: "v0.7.0", gatedProbe: true)
        let settings = testSettings()
        settings.customBinaryPath = older.path
        let manager = RuleManager(store: RuleStore(directory: dir.appendingPathComponent("data")),
            locator: BinaryLocator(customPath: { settings.customBinaryPath }, searchDirectories: [], environmentPATH: nil),
            settings: settings)

        let refresh = Task { await manager.refreshTailcatInfo() }
        #expect(await waitUntil { FileManager.default.fileExists(atPath: older.path + ".started") })
        settings.customBinaryPath = modern.path
        await manager.refreshTailcatInfo()
        #expect(manager.capabilities?.serveMappings == true)
        try Data().write(to: older.appendingPathExtension("release"))
        await refresh.value
        #expect(manager.capabilities?.serveMappings == true)
        #expect(manager.versionText == "v0.8.0")
        #expect(manager.tailcatVersion == TailcatVersion(0, 8, 0))
    }
}
