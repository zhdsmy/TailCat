import Foundation
import Testing
@testable import TailCatCore

@MainActor @Suite struct DirectoryWatcherTests {
    @Test func reportsUploadsOnlyAfterTheyStopGrowing() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [[String]] = []
        let watcher = DirectoryWatcher(url: dir, quietPeriod: 0.5) { reported.append($0) }
        watcher.start()
        defer { watcher.stop() }

        // Like tailcat's drop box: create under the final name, then keep writing in place.
        let file = dir.appendingPathComponent("photo.jpg")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 100_000_000)
            handle.write(Data(count: 1024))
        }
        #expect(reported.isEmpty)
        try handle.close()
        #expect(await waitUntil { !reported.isEmpty })
        #expect(reported == [["photo.jpg"]])
    }
}
