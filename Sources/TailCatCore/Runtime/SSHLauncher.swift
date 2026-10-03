import Foundation
import Darwin

/// Opens `tailcat ssh` in Terminal by writing a one-shot `.command` script: Finder hands those to
/// Terminal without the Apple Events permission that scripting Terminal would need.
public enum SSHLauncher {
    public enum CommandMode: String, CaseIterable, Sendable { case ssh, socks }

    public static func commandArguments(remote: Remote, mode: CommandMode, command: [String],
                                        settings: AppSettings = AppSettings()) -> Result<[String], CLIError> {
        guard remote.validate().isEmpty, let first = command.first, !first.isEmpty, !first.hasPrefix("-"),
              command.allSatisfy({ !$0.contains("\0") && !$0.contains(where: \.isNewline) }) else {
            return .failure(CLIError(L10n.tr("请填写有效命令：每行一个参数，第一行是程序，不能以 - 开头。")))
        }
        switch mode {
        case .ssh:
            // OpenSSH joins command arguments into a remote shell string. Quote each UI argument
            // there too, so spaces and shell metacharacters survive both boundaries literally.
            let remoteCommand = command.map(ShellQuote.quote).joined(separator: " ")
            return .success(arguments(identity: remote.identity, user: remote.sshUser, port: remote.sshPort, settings: settings) + [remoteCommand])
        case .socks:
            return .success(settings.globalFlagArguments(key: remote.key) + ["socks", remote.address] + command)
        }
    }

    public static func arguments(identity: ClientIdentity, user: String, port: String,
                                 settings: AppSettings = AppSettings()) -> [String] {
        var args = settings.globalFlagArguments(key: identity.key) + ["ssh"]
        let p = port.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty && p != "22" { args.append(contentsOf: ["-p", p]) }
        args.append(user.isEmpty ? identity.address : "\(user)@\(identity.address)")
        return args
    }

    /// The script deletes itself first: it contains the address, which is a credential.
    public static func script(executable: URL, arguments: [String]) -> String {
        let command = ([executable.path] + arguments).map(ShellQuote.quote).joined(separator: " ")
        return """
        #!/bin/sh
        rm -f "$0"
        exec \(command)

        """
    }

    public static func writeScript(executable: URL, arguments: [String]) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("TailCat-ssh", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("ssh-\(UUID().uuidString.prefix(8)).command")
        let data = Data(script(executable: executable, arguments: arguments).utf8)
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// `-p` accepts a port or, through an exit-node server, `ip:port` / bare IP.
    public static func isValidPort(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.contains("\0"), !t.contains(where: \.isNewline) else { return false }
        if t.isEmpty || MappingSpec.port(t, allowZero: false) != nil || MappingSpec.isIPv4(t) { return true }
        func isIPv6(_ text: String) -> Bool {
            var address = in6_addr()
            return text.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        if isIPv6(t) { return true }
        guard let colon = t.lastIndex(of: ":"),
              MappingSpec.port(String(t[t.index(after: colon)...]), allowZero: false) != nil else { return false }
        let host = String(t[..<colon])
        if MappingSpec.isIPv4(host) { return true }
        return host.hasPrefix("[") && host.hasSuffix("]") && isIPv6(String(host.dropFirst().dropLast()))
    }
}
