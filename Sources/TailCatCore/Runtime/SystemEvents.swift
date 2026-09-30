import AppKit
import Foundation
import Network

/// Fires when the machine wakes from sleep or the network path changes, both of which silently
/// break WireGuard/DERP sessions that `tailcat forward` will not notice on its own.
@MainActor
public final class SystemEvents {
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var lastSignature: String?
    private var debounce: Task<Void, Never>?

    public init() {}

    public func start(debounce interval: TimeInterval = 3, onChange: @escaping @MainActor (String) -> Void) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire("系统唤醒", after: interval, onChange) }
        }

        monitor.pathUpdateHandler = { [weak self] path in
            // Interface set + status; ignores no-op updates and the initial callback.
            let signature = "\(path.status)|" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.lastSignature = signature }
                guard let previous = self.lastSignature, previous != signature,
                      path.status == .satisfied else { return }
                self.fire("网络变化", after: interval, onChange)
            }
        }
        monitor.start(queue: DispatchQueue(label: "tailcat.netmonitor"))
    }

    private func fire(_ reason: String, after interval: TimeInterval, _ onChange: @escaping @MainActor (String) -> Void) {
        debounce?.cancel()
        debounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if !Task.isCancelled { onChange(reason) }
        }
    }

    public func stop() {
        monitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        debounce?.cancel()
    }
}
