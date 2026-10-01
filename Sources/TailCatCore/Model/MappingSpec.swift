import Foundation

/// One `[local:]remote` or `local:ip:remote` mapping as accepted by `tailcat forward`.
public struct MappingSpec: Equatable, Sendable {
    /// 0 asks the OS for a free port.
    public var localPort: Int
    /// Set for exit-node style mappings (`3306:192.168.1.10:3306`).
    public var remoteHost: String?
    public var remotePort: Int

    public static func parse(_ raw: String) -> MappingSpec? {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        switch parts.count {
        case 1:
            guard let port = port(parts[0], allowZero: false) else { return nil }
            return MappingSpec(localPort: port, remoteHost: nil, remotePort: port)
        case 2:
            guard let local = port(parts[0], allowZero: true),
                  let remote = port(parts[1], allowZero: false) else { return nil }
            return MappingSpec(localPort: local, remoteHost: nil, remotePort: remote)
        case 3:
            guard let local = port(parts[0], allowZero: true),
                  isIPv4(parts[1]),
                  let remote = port(parts[2], allowZero: false) else { return nil }
            return MappingSpec(localPort: local, remoteHost: parts[1], remotePort: remote)
        default:
            return nil
        }
    }

    /// Human-readable form for the UI, e.g. "本机 2222 → 远端 22".
    public var displayLabel: String {
        let local = localPort == 0 ? "本机 自动分配端口" : "本机 \(localPort)"
        if let remoteHost { return "\(local) → \(remoteHost):\(remotePort)（经远端）" }
        return "\(local) → 远端 \(remotePort)"
    }

    static func port(_ s: String, allowZero: Bool) -> Int? {
        guard !s.isEmpty, s.count <= 5, s.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(s) else { return nil }
        return (allowZero ? 0 : 1)...65535 ~= value ? value : nil
    }

    static func isIPv4(_ s: String) -> Bool {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { o in
            !o.isEmpty && o.count <= 3 && o.allSatisfy { $0.isASCII && $0.isNumber } && Int(o)! <= 255
        }
    }
}

/// One item of `tailcat serve`'s port/service list.
public enum ServeItem {
    public static let namedServices = ["all", "exit-node", "ssh", "no-auth-ssh", "files", "exec", "perf"]

    /// Accepts service names, ports, ranges (`8000-8999`), and mappings to localhost (`8080:80`)
    /// or to a host on the server's network (`5555:192.168.1.10:5555`, `5555:[fd7a::1]:5555`).
    public static func isValid(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if namedServices.contains(s) { return true }
        if MappingSpec.port(s, allowZero: false) != nil { return true }
        if let dash = s.firstIndex(of: "-"), !s.contains(":") {
            guard let lo = MappingSpec.port(String(s[..<dash]), allowZero: false),
                  let hi = MappingSpec.port(String(s[s.index(after: dash)...]), allowZero: false)
            else { return false }
            return lo <= hi
        }
        guard let colon = s.firstIndex(of: ":"),
              MappingSpec.port(String(s[..<colon]), allowZero: false) != nil else { return false }
        let target = String(s[s.index(after: colon)...])
        if MappingSpec.port(target, allowZero: false) != nil { return true }
        guard let last = target.lastIndex(of: ":"),
              MappingSpec.port(String(target[target.index(after: last)...]), allowZero: false) != nil
        else { return false }
        let host = String(target[..<last])
        if MappingSpec.isIPv4(host) { return true }
        return host.hasPrefix("[") && host.hasSuffix("]") && host.count > 2
            && host.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" }
    }

    /// The tunnel-side port a client connects to, for suggesting peer commands.
    public static func servedPort(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let head = s.split(whereSeparator: { $0 == ":" || $0 == "-" }).first.map(String.init) ?? s
        return MappingSpec.port(head, allowZero: false)
    }
}
