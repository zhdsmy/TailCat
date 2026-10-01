import Foundation
import Testing
@testable import TailCatCore

@MainActor @Suite struct DirectoryWatcherTests {
    @Test func reportsUploadsOnlyAfterTheyStopGrowing() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [[String]] = []
        // The quiet period never elapses here: the test steps rescan/settle itself.
        let watcher = DirectoryWatcher(url: dir, quietPeriod: 3600) { reported.append($0) }
        watcher.start()
        defer { watcher.stop() }

        // Like tailcat's drop box: create under the final name, then keep writing in place.
        let file = dir.appendingPathComponent("photo.jpg")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".DS_Store").path, contents: nil)
        watcher.rescan()
        let handle = try FileHandle(forWritingTo: file)
        handle.write(Data(count: 1024))
        watcher.settle()
        #expect(reported.isEmpty)
        handle.write(Data(count: 1024))
        watcher.settle()
        #expect(reported.isEmpty)
        try handle.close()
        watcher.settle()
        #expect(reported == [["photo.jpg"]])
        watcher.settle()
        #expect(reported.count == 1)
    }

    @Test func dropsItemsRemovedBeforeTheySettle() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [[String]] = []
        let watcher = DirectoryWatcher(url: dir, quietPeriod: 3600) { reported.append($0) }
        watcher.start()
        defer { watcher.stop() }

        let file = dir.appendingPathComponent("partial.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        watcher.rescan()
        try FileManager.default.removeItem(at: file)
        watcher.settle()
        watcher.settle()
        #expect(reported.isEmpty)
    }
}
