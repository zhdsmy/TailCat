import AppKit
import SwiftUI
import TailCatCore

extension RunState {
    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中…"
        case .running: return "已启动"
        case .reconnecting(let attempt, let retryAt, _):
            let secs = max(0, Int(retryAt.timeIntervalSinceNow.rounded(.up)))
            return "重连中（第 \(attempt) 次，\(secs)s 后）"
        case .failed(let reason): return "失败：\(Diagnostics.mask(reason))"
        }
    }

    /// Failing or retrying: the log explains why, so detail views open it.
    var needsAttention: Bool {
        switch self {
        case .reconnecting, .failed: return true
        case .stopped, .starting, .running: return false
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .starting, .reconnecting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}

struct StatusDot: View {
    let state: RunState
    var body: some View {
        Circle().fill(state.color).frame(width: 9, height: 9)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static var string: String? { NSPasteboard.general.string(forType: .string) }
}

enum Panels {
    @MainActor
    static func chooseDirectory(message: String, prompt: String = "选择") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseFiles(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = message
        panel.prompt = "发送"
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Monospaced value with a copy button. `secret` text contains tc addresses, which are bearer
/// credentials: they stay masked on screen (screenshots, screen sharing) until revealed, while
/// copying always yields the full text.
struct CopyableText: View {
    let text: String
    var font: Font = .body.monospaced()
    var lineLimit: Int? = 1
    var secret = false
    /// Several rows showing the same address follow one toggle owned by the caller; such rows show
    /// no eye button of their own.
    var sharedReveal: Binding<Bool>?
    var copyLabel: String? = nil
    @ViewState private var ownReveal = false

    private var revealed: Bool { sharedReveal?.wrappedValue ?? ownReveal }

    var body: some View {
        HStack(spacing: 6) {
            Text(secret && !revealed ? Diagnostics.mask(text) : text)
                .font(font)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(secret && !revealed ? "地址已隐藏；复制可获得完整内容" : text)
            if secret && sharedReveal == nil {
                Button { ownReveal.toggle() } label: { Image(systemName: ownReveal ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(ownReveal ? "隐藏" : "显示完整内容")
                    .accessibilityLabel(ownReveal ? "隐藏完整内容" : "显示完整内容")
            }
            CopyButton(text: text, label: copyLabel ?? (secret ? "复制完整内容" : "复制"))
                .buttonStyle(.borderless)
        }
    }
}

struct CopyButton: View {
    let text: String
    var label = "复制"
    var iconOnly = true
    @ViewState var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                if copied || !iconOnly { Text(copied ? "已复制" : label) }
            }
        }
        .help(label)
        .accessibilityLabel(copied ? "已复制" : label)
        .fixedSize()
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            copied = false
        }
        .onChange(of: text) { _ in copied = false }
    }
}

/// First-run blocker: nothing works until tailcat is installed or its path is set.
struct MissingTailcat: View {
    @EnvironmentObject var manager: RuleManager
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("未找到 tailcat", systemImage: "exclamationmark.triangle.fill")
                .font(compact ? .callout.weight(.semibold) : .headline).foregroundStyle(.red)
            if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已安装 Homebrew 时，将下方命令复制到“终端”执行。")
                    Text("完成后点“重新检测”；已有 tailcat 可在设置中指定路径。")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                CopyableText(text: "brew install tailcat", font: .callout.monospaced(), copyLabel: "复制安装命令")
                Spacer()
                Button("重新检测") { Task { await manager.refreshTailcatInfo() } }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "12 秒前"; refreshes itself so it does not go stale while the view stays open.
struct Ago: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            Text(Self.format(date)).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func format(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        if s < 10 { return "刚刚" }
        if s < 60 { return "\(s) 秒前" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        return "\(s / 3600) 小时前"
    }
}

/// Green direct, orange relayed, red unreachable, grey unknown.
struct RemoteStatusDot: View {
    let status: RemotePing?

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private var color: Color {
        guard let status else { return .secondary.opacity(0.5) }
        guard let result = status.result else { return .red }
        return result.isDirect ? .green : .orange
    }
}

struct Badge: View {
    let text: String
    var color: Color = .orange
    var systemImage: String = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(Diagnostics.mask(text)).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(color)
    }
}

struct PingLabel: View {
    let ping: PingResult
    var font: Font = .caption2
    var body: some View {
        Text(ping.shortLabel).font(font).foregroundStyle(ping.isDirect ? .green : .orange)
            .help("最近一次连接探测结果；中继连接也可使用。探测成功不代表远端的具体服务可用。")
    }
}

extension TunnelKind {
    /// Order used by the menu and sidebar.
    static let displayOrder: [TunnelKind] = [.forward, .socks, .serve, .recv]
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
