import Foundation

/// Builds a shareable report. tc… addresses are bearer credentials, so every one is masked.
public enum Diagnostics {
    private static let addressPattern = try! NSRegularExpression(pattern: #"tc[A-Za-z0-9_\-]{20,}"#)

    public static func mask(_ text: String) -> String {
        let ns = text as NSString
        var result = text
        for match in addressPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let addr = ns.substring(with: match.range)
            let masked = String(addr.prefix(6)) + "…(\(addr.count) 字符)"
            result = (result as NSString).replacingCharacters(in: match.range, with: masked)
        }
        return result
    }

    public static func report(
        appVersion: String,
        tailcatVersion: String?,
        rule: TunnelRule,
        commandLine: String,
        state: String,
        lastPing: PingResult?,
        log: [String],
        date: Date = Date()
    ) -> String {
        var lines = [
            "TailCat 诊断信息",
            "时间：\(ISO8601DateFormatter().string(from: date))",
            "App：\(appVersion)",
            "tailcat：\(tailcatVersion ?? "未知")",
            "macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "规则：\(rule.name)（\(rule.kind.label)）",
            "状态：\(state)",
            "命令：\(commandLine)",
            "最后一次 ping：\(lastPing?.detailLabel ?? "无")",
            "",
            "最近日志：",
        ]
        lines.append(contentsOf: log.suffix(80))
        return mask(lines.joined(separator: "\n"))
    }
}
