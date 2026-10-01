import Foundation

/// Reports files that appear in a directory (the recv drop box). Watches only the top level:
/// flat drop boxes put every upload there, and `--accept-dirs` uploads show up as a new directory.
///
/// tailcat's drop box creates each upload under its final name and writes it in place, so a new
/// item is reported only after its size and modification time hold still for `quietPeriod`;
/// otherwise the notification would point at a half-written file.
@MainActor
public final class DirectoryWatcher {
    public let url: URL
    private let quietPeriod: TimeInterval
    private let onNewItems: ([String]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    /// New items not yet reported, with what they looked like at the last check.
    private var pending: [String: Fingerprint] = [:]
    private var settleTask: Task<Void, Never>?

    public init(url: URL, quietPeriod: TimeInterval = 2, onNewItems: @escaping ([String]) -> Void) {
        self.url = url
        self.quietPeriod = quietPeriod
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
        settleTask?.cancel()
        settleTask = nil
        pending = [:]
    }

    private func rescan() {
        let now = Self.listing(url)
        for name in now.subtracting(known) { pending[name] = fingerprint(name) }
        known = now
        scheduleSettle()
    }

    private func scheduleSettle() {
        guard settleTask == nil, !pending.isEmpty else { return }
        let delay = UInt64(quietPeriod * 1_000_000_000)
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    private func settle() {
        settleTask = nil
        var settled: [String] = []
        for (name, last) in pending {
            let current = fingerprint(name)
            if current == nil { pending[name] = nil }  // removed before it finished
            else if current == last { settled.append(name); pending[name] = nil }
            else { pending[name] = current }
        }
        if !settled.isEmpty { onNewItems(settled.sorted()) }
        scheduleSettle()
    }

    private struct Fingerprint: Equatable {
        var files = 0
        var bytes = 0
        var modified = Date.distantPast

        mutating func add(_ url: URL) {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
            files += 1
            bytes += v.fileSize ?? 0
            modified = max(modified, v.contentModificationDate ?? .distantPast)
        }
    }

    /// Size and newest modification over the item and, for an uploaded directory, everything in it.
    private func fingerprint(_ name: String) -> Fingerprint? {
        let item = url.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: item.path) else { return nil }
        var f = Fingerprint()
        f.add(item)
        let children = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        while let child = children?.nextObject() as? URL { f.add(child) }
        return f
    }

    private static func listing(_ url: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }
}
