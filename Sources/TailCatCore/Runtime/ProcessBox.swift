import Foundation

/// Owns a running `Process` so it can be signalled from cancellation handlers and other threads.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var unhealthy = false
    private var killed = false

    init(_ process: Process) {
        self.process = process
    }

    var processIdentifier: Int32 { process.processIdentifier }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process.isRunning
    }

    /// Set when the health check (not the process itself) decided the tunnel is dead.
    var markedUnhealthy: Bool {
        lock.lock(); defer { lock.unlock() }
        return unhealthy
    }

    func markUnhealthy() {
        lock.lock(); defer { lock.unlock() }
        unhealthy = true
    }

    /// SIGTERM, then SIGKILL after `grace` if it is still alive.
    func terminate(grace: TimeInterval = 3) {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [process] in
            if process.isRunning { Foundation.kill(pid, SIGKILL) }
        }
    }

    /// Launches unless `kill()` came first: a task cancelled before launch has already run its
    /// cancellation handler, so nothing would stop the command afterwards.
    func run() throws {
        lock.lock(); defer { lock.unlock() }
        if killed { throw CancellationError() }
        try process.run()
    }

    func kill() {
        lock.lock(); defer { lock.unlock() }
        killed = true
        guard process.isRunning else { return }
        Foundation.kill(process.processIdentifier, SIGKILL)
    }

    /// Blocking variant for app shutdown, where no scheduled work will get to run.
    func terminateAndWait(timeout: TimeInterval) {
        lock.lock()
        guard process.isRunning else { lock.unlock(); return }
        process.terminate()
        let pid = process.processIdentifier
        lock.unlock()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning { return }
            usleep(20_000)
        }
        if isRunning { Foundation.kill(pid, SIGKILL) }
    }
}

public struct ProcessOutput: Sendable {
    public var status: Int32?
    public var stdout: String
    public var stderr: String

    public init(status: Int32?, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Last non-empty stderr line, for error messages.
    public var errorSummary: String {
        stderr.split(whereSeparator: \.isNewline).map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "退出码 \(status.map(String.init) ?? "?")"
    }
}

/// Reads pipes with blocking `read()` on dedicated threads. Tunnel readers stay blocked for as long
/// as the tunnel runs, which would pin GCD workers; and `FileHandle.bytes` readers were seen to
/// stall entirely while another process's pipe was drained with `readDataToEndOfFile`.
enum PipeReader {
    static func lines(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            startThread {
                var pending = Data()
                readLoop(handle) { chunk in
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        continuation.yield(decodeLine(pending[pending.startIndex..<nl]))
                        pending.removeSubrange(pending.startIndex...nl)
                    }
                }
                if !pending.isEmpty { continuation.yield(decodeLine(pending[...])) }
                continuation.finish()
            }
        }
    }

    /// Everything until EOF. Start it right after launch: a child that fills the ~64 KiB pipe
    /// buffer blocks forever if nobody reads until it exits.
    static func readAll(_ handle: FileHandle) -> Task<String, Never> {
        let stream = AsyncStream<Data> { continuation in
            startThread {
                readLoop(handle) { continuation.yield($0) }
                continuation.finish()
            }
        }
        return Task {
            var all = Data()
            for await chunk in stream { all.append(chunk) }
            return String(decoding: all, as: UTF8.self)
        }
    }

    private static func readLoop(_ handle: FileHandle, _ body: (Data) -> Void) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                body(Data(buffer[0..<n]))
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        // The handle owns the fd; keep it open until the loop is done with it.
        withExtendedLifetime(handle) {}
    }

    private static func decodeLine(_ data: Data.SubSequence) -> String {
        var line = String(decoding: data, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }

    private static func startThread(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "tailcat.pipe-reader"
        thread.start()
    }
}

enum ProcessRunner {
    /// Runs a short-lived command and returns its exit status, or nil if it could not be launched.
    /// The command is SIGKILLed after `hardTimeout` and when the calling task is cancelled.
    static func exitStatus(of executable: URL, arguments: [String], hardTimeout: TimeInterval) async -> Int32? {
        await run(executable: executable, arguments: arguments, hardTimeout: hardTimeout,
                  captureOutput: false).status
    }

    /// Like `exitStatus`, but also returns captured stdout and stderr (decoded as UTF-8).
    static func run(
        executable: URL,
        arguments: [String],
        hardTimeout: TimeInterval,
        captureOutput: Bool = true,
        environment: [String: String]? = nil
    ) async -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        if captureOutput {
            process.standardOutput = outPipe
            process.standardError = errPipe
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        let box = ProcessBox(process)
        var drains: (Task<String, Never>, Task<String, Never>)?

        let status: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try box.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: nil)
                    return
                }
                // Process closes the parent's write ends itself; closing them again could hit an
                // fd number another concurrent launch has already reused.
                if captureOutput {
                    drains = (PipeReader.readAll(outPipe.fileHandleForReading),
                              PipeReader.readAll(errPipe.fileHandleForReading))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + hardTimeout) { box.kill() }
            }
        } onCancel: {
            box.kill()
        }

        guard let drains else {
            return ProcessOutput(status: status, stdout: "", stderr: "")
        }
        return ProcessOutput(status: status, stdout: await drains.0.value, stderr: await drains.1.value)
    }
}
