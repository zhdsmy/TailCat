import Foundation

/// Builds a shareable report. tc… addresses are bearer credentials, so every one is masked.
public enum Diagnostics {
    private static let addressPattern = try! NSRegularExpression(pattern: #"tc[A-Za-z0-9_\-]{20,}"#)

    public static func mask(_ text: String) -> String {
        let ns = text as NSString
        var result = text
        for match in addressPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let addr = ns.substring(with: match.range)
            let masked = L10n.tr("%@…(%@ 字符)", String(addr.prefix(6)), String(addr.count))
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
            L10n.tr("TailCat 诊断信息"),
            L10n.tr("时间：%@", ISO8601DateFormatter().string(from: date)),
            L10n.tr("App：%@", appVersion),
            L10n.tr("tailcat：%@", tailcatVersion ?? L10n.tr("未知")),
            L10n.tr("macOS：%@", ProcessInfo.processInfo.operatingSystemVersionString),
            L10n.tr("规则：%@（%@）", rule.name, rule.kind.label),
            L10n.tr("状态：%@", state),
            L10n.tr("命令：%@", commandLine),
            L10n.tr("最后一次 ping：%@", lastPing?.detailLabel ?? L10n.tr("无")),
            "",
            L10n.tr("最近日志："),
        ]
        lines.append(contentsOf: log.suffix(80))
        return mask(lines.joined(separator: "\n"))
    }
}
