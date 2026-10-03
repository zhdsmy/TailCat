import Foundation

public struct CLIError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// tailcat echoes rejected input, addresses included, and these messages end up on screen.
    public init(_ message: String) { self.message = Diagnostics.mask(message) }
    public var description: String { message }

    static let binaryNotFound = CLIError(LaunchError.binaryNotFound.description)

    public var needsBinaryCheck: Bool { self == .binaryNotFound }

    public var recoverySuggestion: String {
        if needsBinaryCheck { return L10n.tr("安装或选择 tailcat 后，点击重新检测。") }
        let lower = message.lowercased()
        if lower.contains("no such host") || lower.contains("nxdomain") || lower.contains("no tailcat txt") {
            return L10n.tr("检查远端域名和 tailcat TXT 记录，然后重试。")
        }
        if lower.contains("permission denied") || lower.contains("not allowed") || lower.contains("unauthorized") {
            return L10n.tr("请对方检查允许列表与当前客户端身份；SSH 还需要单独的授权公钥。")
        }
        return L10n.tr("确认远端服务已启动，并检查地址、网络与客户端权限后重试。")
    }
}

/// A DERP region from `genkey --region=list` (stderr lines `  %3d code name`).
public struct DERPRegionInfo: Identifiable, Equatable, Sendable {
    public var id: Int
    public var code: String
    public var name: String

    public init(id: Int, code: String, name: String) {
        self.id = id
        self.code = code
        self.name = name
    }

    public static func parseList(_ text: String) -> [DERPRegionInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let id = Int(parts[0]) else { return nil }
            return DERPRegionInfo(id: id, code: parts[1], name: parts[2])
        }
    }
}

/// Where genkey should bake the server's DERP region.
public enum RegionChoice: Equatable, Sendable {
    /// `--region=auto`: pick by latency at each server start.
    case auto
    /// `--fixed-region`: discover the nearest region now and bake it in (recommended for DNS).
    case nearestNow
    /// `--region=<id|code|name>`.
    case named(String)
    /// `--region=host1,host2`: your own DERP servers, embedded in the address.
    case customHosts(String)
}

/// Wrappers around short-lived `tailcat` subcommands used by the UI.
public struct TailcatCLI: Sendable {
    public var locator: BinaryLocator
    public var settings: AppSettings

    public init(locator: BinaryLocator = BinaryLocator(), settings: AppSettings = AppSettings()) {
        self.locator = locator
        self.settings = settings
    }

    public func executable() -> URL? { locator.locate() }

    private func run(_ args: [String], timeout: TimeInterval) async -> ProcessOutput? {
        guard let exe = executable() else { return nil }
        return await ProcessRunner.run(executable: exe, arguments: args, hardTimeout: timeout)
    }

    private func runChecked(_ args: [String], timeout: TimeInterval) async -> Result<ProcessOutput, CLIError> {
        guard let out = await run(args, timeout: timeout) else { return .failure(.binaryNotFound) }
        guard out.status == 0 else { return .failure(CLIError(out.errorSummary)) }
        return .success(out)
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
    }

    // MARK: Info

    public func version() async -> String? {
        guard let out = await run(["version"], timeout: 5) else { return nil }
        return Self.firstLine(out.stdout)
    }

    /// Version-derived capabilities, confirmed by probing `perf --help` so dev builds that report
    /// an older version string are still detected.
    public func capabilities() async -> (TailcatVersion?, TailcatCapabilities) {
        let version = await version().flatMap(TailcatVersion.parse)
        var caps = TailcatCapabilities.from(version: version)
        if !caps.perf, let out = await run(["perf", "--help"], timeout: 5), out.status == 0 {
            caps.perf = true
        }
        return (version, caps)
    }

    public func parse(address: String) async -> ParsedAddress? {
        guard AddressTools.looksLikeAddress(address) else { return nil }
        guard let out = await run(settings.globalFlagArguments() + ["parse", address], timeout: 15),
              out.status == 0 else { return nil }
        return AddressTools.parseJSON(out.stdout)
    }

    public func resolve(address: String) async -> String? {
        guard AddressTools.looksLikeAddress(address) else { return nil }
        guard let out = await run(settings.globalFlagArguments() + ["resolve", address], timeout: 20),
              out.status == 0 else { return nil }
        return Self.firstLine(out.stdout)
    }

    /// Public key of the client key that `key` selects ("" = `client-default` or ephemeral).
    public func printpub(key: String = "") async -> Result<String, CLIError> {
        await runChecked(settings.globalFlagArguments(key: key) + ["printpub"], timeout: 10).flatMap { out in
            Self.firstLine(out.stdout).map(Result.success) ?? .failure(CLIError(L10n.tr("printpub 没有输出")))
        }
    }

    // MARK: Ping

    public static func ping(executable: URL, identity: ClientIdentity, timeoutSeconds: Int,
                            untilDirect: Bool, settings: AppSettings = AppSettings()) async -> PingResult? {
        try? await probe(executable: executable, identity: identity, timeoutSeconds: timeoutSeconds,
                         untilDirect: untilDirect, settings: settings).get()
    }

    public static func probe(executable: URL, identity: ClientIdentity, timeoutSeconds: Int,
                             untilDirect: Bool, settings: AppSettings = AppSettings()) async -> Result<PingResult, CLIError> {
        let output = await ProcessRunner.run(
            executable: executable,
            arguments: identity.pingArguments(timeoutSeconds: timeoutSeconds, untilDirect: untilDirect, settings: settings),
            hardTimeout: TimeInterval(timeoutSeconds) + 5)
        guard output.status == 0 else { return .failure(CLIError(output.errorSummary)) }
        guard let reply = output.stdout.split(whereSeparator: \.isNewline).reversed()
            .compactMap({ PingResult.parse(String($0)) }).first
        else { return .failure(CLIError(L10n.tr("命令已结束，但无法解析连接探测结果"))) }
        return .success(reply)
    }

    public func probe(_ identity: ClientIdentity, untilDirect: Bool = false, timeoutSeconds: Int = 10) async -> Result<PingResult, CLIError> {
        guard let exe = executable() else { return .failure(.binaryNotFound) }
        return await Self.probe(executable: exe, identity: identity, timeoutSeconds: timeoutSeconds,
                                untilDirect: untilDirect, settings: settings)
    }

    public func ping(_ identity: ClientIdentity, untilDirect: Bool = false, timeoutSeconds: Int = 10) async -> PingResult? {
        guard let exe = executable() else { return nil }
        return await Self.ping(executable: exe, identity: identity, timeoutSeconds: timeoutSeconds,
                               untilDirect: untilDirect, settings: settings)
    }

    // MARK: Keys

    /// Key names are `$CONFIG/tailcat/keys/<name>.private.json`; anything with a slash is a path.
    public static func isValidKeyName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.hasPrefix(".") && name != "new"
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    public func listKeys() async -> Result<[String], CLIError> {
        await runChecked(["genkey", "--list"], timeout: 10).map { out in
            out.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.sorted()
        }
    }

    /// Needs the DERP map, so it may hit the network (tailcat caches it).
    public func listRegions() async -> Result<[DERPRegionInfo], CLIError> {
        await runChecked(settings.globalFlagArguments() + ["genkey", "--region=list"], timeout: 30).map { out in
            DERPRegionInfo.parseList(out.stderr)
        }
    }

    public static func serverKeyArguments(name: String, region: RegionChoice, embedDERPMap: Bool,
                                          psk: Bool, force: Bool) -> [String] {
        var args = ["genkey", "--key=\(name)"]
        switch region {
        case .auto: break
        case .nearestNow: args.append("--fixed-region")
        case .named(let r): args.append("--region=\(r)")
        case .customHosts(let h): args.append("--region=\(h)")
        }
        if embedDERPMap { args.append("--embed-derp-map") }
        if !psk { args.append("--psk=false") }
        if force { args.append("--force") }
        return args
    }

    /// Returns the new server's tailcat address.
    public func generateServerKey(name: String, region: RegionChoice, embedDERPMap: Bool = false,
                                  psk: Bool = true, force: Bool = false) async -> Result<String, CLIError> {
        guard Self.isValidKeyName(name) else { return .failure(CLIError(L10n.tr("key 名称只能包含字母、数字、. _ -"))) }
        let args = settings.globalFlagArguments()
            + Self.serverKeyArguments(name: name, region: region, embedDERPMap: embedDERPMap, psk: psk, force: force)
        return await runChecked(args, timeout: 60).flatMap { out in
            Self.firstLine(out.stdout).map(Result.success) ?? .failure(CLIError(L10n.tr("genkey 没有输出地址")))
        }
    }

    /// Returns the new client identity's public key.
    public func generateClientKey(name: String, force: Bool = false) async -> Result<String, CLIError> {
        guard Self.isValidKeyName(name) else { return .failure(CLIError(L10n.tr("key 名称只能包含字母、数字、. _ -"))) }
        var args = ["genkey", "--client", "--key=\(name)"]
        if force { args.append("--force") }
        return await runChecked(args, timeout: 20).flatMap { out in
            Self.firstLine(out.stdout).map(Result.success) ?? .failure(CLIError(L10n.tr("genkey 没有输出公钥")))
        }
    }

    public func deleteKey(name: String) async -> Result<Void, CLIError> {
        guard Self.isValidKeyName(name) else { return .failure(CLIError(L10n.tr("无效的 key 名称"))) }
        return await runChecked(["genkey", "--delete", "--key=\(name)"], timeout: 10).map { _ in () }
    }

    // MARK: Files

    /// `<addr>[:path]` for ls/cp; the path is relative to the server's served directory.
    public static func remoteArg(_ identity: ClientIdentity, path: String) -> String {
        path.isEmpty || path == "." ? identity.address : "\(identity.address):\(path)"
    }

    public func list(_ identity: ClientIdentity, path: String) async -> Result<[RemoteFileEntry], CLIError> {
        let args = settings.globalFlagArguments(key: identity.key) + ["ls", "-l", Self.remoteArg(identity, path: path)]
        return await runChecked(args, timeout: 45).map { FileListing.parse($0.stdout) }
    }

    public static func copyArguments(identity: ClientIdentity, sources: [String], target: String,
                                     recursive: Bool, preserve: Bool, port: Int = 22, settings: AppSettings = AppSettings()) -> [String] {
        var args = settings.globalFlagArguments(key: identity.key) + ["cp"]
        if recursive { args.append("-r") }
        if preserve { args.append("-p") }
        if port != 22 { args += ["-P", String(port)] }
        return args + sources + [target]
    }

    /// Uploads local absolute paths into `remotePath` (a directory, "" = the served root).
    /// Cancelling the calling task kills the copy.
    public func upload(_ identity: ClientIdentity, files: [URL], remotePath: String,
                       preserve: Bool = false, port: Int = 22) async -> Result<Void, CLIError> {
        guard (1...65535).contains(port) else { return .failure(CLIError(L10n.tr("文件端口必须在 1–65535 之间"))) }
        let recursive = files.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let target = "\(identity.address):\(remotePath == "." ? "" : remotePath)"
        let args = Self.copyArguments(identity: identity, sources: files.map(\.path), target: target,
                                      recursive: recursive, preserve: preserve, port: port, settings: settings)
        return await runChecked(args, timeout: 6 * 3600).map { _ in () }
    }

    public func download(_ identity: ClientIdentity, remotePath: String, isDirectory: Bool,
                         to localDirectory: URL, preserve: Bool = false, port: Int = 22) async -> Result<Void, CLIError> {
        guard (1...65535).contains(port) else { return .failure(CLIError(L10n.tr("文件端口必须在 1–65535 之间"))) }
        let args = Self.copyArguments(identity: identity, sources: ["\(identity.address):\(remotePath)"],
                                      target: localDirectory.path + "/", recursive: isDirectory,
                                      preserve: preserve, port: port, settings: settings)
        return await runChecked(args, timeout: 6 * 3600).map { _ in () }
    }

    // MARK: Perf

    public static func perfArguments(identity: ClientIdentity, options: PerfOptions,
                                     settings: AppSettings = AppSettings()) -> [String] {
        settings.globalFlagArguments(key: identity.key) + ["--json", "perf"] + options.arguments() + [identity.address]
    }

    public func perf(_ identity: ClientIdentity, options: PerfOptions) async -> Result<PerfReport, CLIError> {
        let args = Self.perfArguments(identity: identity, options: options, settings: settings)
        return await runChecked(args, timeout: options.hardTimeout).flatMap { out in
            PerfReport.decode(out.stdout).map(Result.success) ?? .failure(CLIError(L10n.tr("无法解析 perf 输出")))
        }
    }
}
