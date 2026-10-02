import Combine
import Foundation

public struct FileTransfer: Identifiable, Sendable {
    public enum Operation: Sendable {
        case upload(files: [URL], path: String)
        case download(path: String, isDirectory: Bool, destination: URL)
    }
    public enum State: Equatable, Sendable {
        case running, cancelling, succeeded, cancelled, failed(String)

        public var isActive: Bool { self == .running || self == .cancelling }
        public var label: String {
            switch self {
            case .running: return L10n.tr("传输中")
            case .cancelling: return L10n.tr("正在取消…")
            case .succeeded: return L10n.tr("已完成")
            case .cancelled: return L10n.tr("已取消")
            case .failed: return L10n.tr("传输失败")
            }
        }
    }

    public let id: UUID
    /// Captures the destination at submission, so editing a remote cannot redirect a retry.
    public let remote: Remote
    public let operation: Operation
    public let preserve: Bool
    public let startedAt: Date
    public var endedAt: Date?
    public var state: State

    public init(id: UUID = UUID(), remote: Remote, operation: Operation, preserve: Bool = false,
                startedAt: Date = Date(), endedAt: Date? = nil, state: State = .running) {
        self.id = id
        self.remote = remote
        self.operation = operation
        self.preserve = preserve
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
    }

    public var label: String {
        switch operation {
        case .upload(let files, _): return files.map(\.lastPathComponent).joined(separator: L10n.tr("、"))
        case .download(let path, _, _): return (path as NSString).lastPathComponent
        }
    }

    public var downloadedURL: URL? {
        guard state == .succeeded, case .download(let path, _, let directory) = operation else { return nil }
        return directory.appendingPathComponent((path as NSString).lastPathComponent)
    }
}

/// In-memory jobs outlive individual pages; the CLI remains responsible for copying bytes.
@MainActor
public final class TransferManager: ObservableObject {
    @Published public private(set) var items: [FileTransfer] = []
    public var onNotify: ((String, String) -> Void)?
    private let cli: TailcatCLI
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(cli: TailcatCLI) { self.cli = cli }
    public var activeCount: Int { items.filter { $0.state.isActive }.count }

    @discardableResult
    public func start(remote: Remote, operation: FileTransfer.Operation, preserve: Bool = false) -> UUID {
        let item = FileTransfer(remote: remote, operation: operation, preserve: preserve)
        items.insert(item, at: 0)
        tasks[item.id] = Task { [weak self, cli] in
            let result: Result<Void, CLIError>
            switch operation {
            case .upload(let files, let path):
                result = await cli.upload(remote.identity, files: files, remotePath: path, preserve: preserve, port: remote.filePort)
            case .download(let path, let isDirectory, let destination):
                result = await cli.download(remote.identity, remotePath: path, isDirectory: isDirectory,
                                            to: destination, preserve: preserve, port: remote.filePort)
            }
            guard let self, let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            if Task.isCancelled {
                self.items[index].state = .cancelled
            } else {
                switch result {
                case .success: self.items[index].state = .succeeded
                case .failure(let error): self.items[index].state = .failed(error.message)
                }
            }
            self.items[index].endedAt = Date()
            self.tasks[item.id] = nil
            self.onNotify?(remote.name, L10n.tr("%@：%@", self.items[index].state.label, item.label))
        }
        return item.id
    }

    public func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isActive else { return }
        items[index].state = .cancelling
        tasks[id]?.cancel()
    }

    public func retry(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch item.state {
        case .cancelled, .failed: start(remote: item.remote, operation: item.operation, preserve: item.preserve)
        default: break
        }
    }

    public func clearFinished() { items.removeAll { !$0.state.isActive } }
    public func shutdown() { for task in tasks.values { task.cancel() } }
}
