import Foundation

/// Reports files that appear in a directory (the recv drop box). Watches only the top level:
/// flat drop boxes put every upload there, and `--accept-dirs` uploads show up as a new directory.
@MainActor
public final class DirectoryWatcher {
    public let url: URL
    private let onNewItems: ([String]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []

    public init(url: URL, onNewItems: @escaping ([String]) -> Void) {
        self.url = url
        self.onNewItems = onNewItems
    }

    public func start() {
        stop()
        known = Self.listing(url)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func rescan() {
        let now = Self.listing(url)
        let added = now.subtracting(known).sorted()
        known = now
        if !added.isEmpty { onNewItems(added) }
    }

    private static func listing(_ url: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }
}
