import Foundation

/// Opens `tailcat ssh` in Terminal by writing a one-shot `.command` script: Finder hands those to
/// Terminal without the Apple Events permission that scripting Terminal would need.
public enum SSHLauncher {
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
        return t.isEmpty || (!t.hasPrefix("-") && t.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ":") })
    }
}
