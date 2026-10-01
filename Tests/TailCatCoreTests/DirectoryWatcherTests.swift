import Foundation
import Testing
@testable import TailCatCore

@MainActor @Suite struct DirectoryWatcherTests {
    @Test func reportsUploadsOnlyAfterTheyStopGrowing() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [[String]] = []
        let watcher = DirectoryWatcher(url: dir, quietPeriod: 10) { reported.append($0) }
        watcher.start()
        defer { watcher.stop() }
        let start = ContinuousClock().now

        // Like tailcat's drop box: create under the final name, then keep writing in place.
        let file = dir.appendingPathComponent("photo.jpg")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".DS_Store").path, contents: nil)
        watcher.rescan(now: start)
        let handle = try FileHandle(forWritingTo: file)
        handle.write(Data(count: 1024))
        watcher.rescan(now: start.advanced(by: .seconds(5)))
        #expect(reported.isEmpty)
        handle.write(Data(count: 1024))
        watcher.settle(now: start.advanced(by: .seconds(9)))
        #expect(reported.isEmpty)
        try handle.close()
        watcher.settle(now: start.advanced(by: .seconds(18)))
        #expect(reported.isEmpty)
        watcher.settle(now: start.advanced(by: .seconds(19)))
        #expect(reported == [["photo.jpg"]])
        watcher.settle(now: start.advanced(by: .seconds(20)))
        #expect(reported.count == 1)
    }

    @Test func reportsEachFileAfterItsOwnQuietPeriod() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [[String]] = []
        let watcher = DirectoryWatcher(url: dir, quietPeriod: 10) { reported.append($0) }
        watcher.start()
        defer { watcher.stop() }
        let start = ContinuousClock().now

        FileManager.default.createFile(atPath: dir.appendingPathComponent("first.bin").path, contents: nil)
        watcher.rescan(now: start)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("second.bin").path, contents: nil)
        watcher.rescan(now: start.advanced(by: .seconds(8)))

        watcher.settle(now: start.advanced(by: .seconds(10)))
        #expect(reported == [["first.bin"]])
        watcher.settle(now: start.advanced(by: .seconds(17)))
        #expect(reported == [["first.bin"]])
        watcher.settle(now: start.advanced(by: .seconds(18)))
        #expect(reported == [["first.bin"], ["second.bin"]])
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
        let start = ContinuousClock().now
        watcher.rescan(now: start)
        try FileManager.default.removeItem(at: file)
        watcher.settle(now: start.advanced(by: .seconds(3600)))
        watcher.settle(now: start.advanced(by: .seconds(7200)))
        #expect(reported.isEmpty)
    }
}
