import Foundation
import Testing
@testable import TailCatCore

@Suite struct PersistenceSafetyTests {
    @Test func readFailureBlocksWritesUntilSuccessfulReload() throws {
        let fm = FileManager.default
        let dir = tempDir()
        let store = RuleStore(directory: dir)
        defer { try? fm.removeItem(at: dir) }
        let original = [TunnelRule(name: "original", kind: .serve, services: ["80"])]
        try store.save(original)
        let data = try Data(contentsOf: store.fileURL)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        #expect(throws: (any Error).self) { try store.load() }
        // Merely restoring permissions cannot make the in-memory empty list safe to save.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(throws: RuleStoreError.self) { try store.save([]) }
        #expect(try Data(contentsOf: store.fileURL) == data)
        #expect(try store.load() == original)
        try store.save([])
        #expect(try store.load().isEmpty)
    }

    @Test func unknownVersionsKeepOriginalFilesEvenWithUnknownItemSchema() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rules = RuleStore(directory: dir)
        let remotes = ListStore<Remote>(fileURL: dir.appendingPathComponent("remotes.json"))
        let future = Data(#"{"version":999,"futureItems":{"important":"keep"}}"#.utf8)
        try SecureFile.write(future, to: rules.fileURL)
        try SecureFile.write(future, to: remotes.fileURL)
        #expect(throws: RuleStoreError.self) { try rules.load() }
        #expect(throws: RuleStoreError.self) { try remotes.load() }
        #expect(throws: RuleStoreError.self) { try rules.save([]) }
        #expect(throws: RuleStoreError.self) { try remotes.save([]) }
        #expect(try Data(contentsOf: rules.fileURL) == future)
        #expect(try Data(contentsOf: remotes.fileURL) == future)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }

    @Test func unreadableListAndFailedBackupCannotBeOverwritten() throws {
        let fm = FileManager.default
        let dir = tempDir()
        let store = ListStore<Remote>(fileURL: dir.appendingPathComponent("remotes.json"))
        defer {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: store.fileURL.path)
            try? fm.removeItem(at: dir)
        }
        try store.save([Remote(name: "box", address: "tcEXAMPLE")])
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        #expect(throws: (any Error).self) { try store.load() }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(throws: RuleStoreError.self) { try store.save([]) }
        #expect(try store.load().count == 1)

        let corrupt = Data("broken JSON".utf8)
        try SecureFile.write(corrupt, to: store.fileURL)
        try fm.setAttributes([.immutable: true], ofItemAtPath: store.fileURL.path)
        do {
            _ = try store.load()
            Issue.record("Locked corrupt file should fail to load")
        } catch RuleStoreError.corrupt {
            Issue.record("Failed rename must not claim that a backup exists")
        } catch { }
        try fm.setAttributes([.immutable: false], ofItemAtPath: store.fileURL.path)
        #expect(throws: RuleStoreError.self) { try store.save([]) }
        #expect(try Data(contentsOf: store.fileURL) == corrupt)
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["remotes.json"])
        // A successful reload now makes a real backup and allows a fresh list.
        #expect(throws: RuleStoreError.self) { try store.load() }
        try store.save([])
        let backups = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("remotes.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == corrupt)
    }
}
