import AppKit
import SwiftUI
import TailCatCore

struct MenuContent: View {
    @EnvironmentObject var manager: RuleManager
    @EnvironmentObject var navigation: Navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if manager.binaryPath == nil {
                MissingTailcat(compact: true).padding(8)
            }
            if manager.runners.isEmpty {
                Text("还没有规则，点“管理…”新建").foregroundStyle(.secondary).padding(12)
            }
            ForEach(TunnelKind.displayOrder, id: \.self) { kind in
                let runners = manager.runners.filter { $0.rule.kind == kind }
                if !runners.isEmpty {
                    Label(kind.label, systemImage: kind.systemImage)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 8)
                    ForEach(runners) { runner in
                        MenuRow(runner: runner) { show(.rule(runner.id)) }
                    }
                }
            }
            Divider().padding(.vertical, 4)
            HStack {
                Button("管理…") { show(nil) }
                Button("接收…") { startReceiving() }.help("选择一个目录，开始接收别人发来的文件")
                if !manager.remotes.isEmpty {
                    Menu("发送…") {
                        ForEach(manager.remotes) { remote in
                            Button(remote.name) {
                                NSApp.activate(ignoringOtherApps: true)
                                FileSender.send(Panels.chooseFiles(message: "选择要发送到 \(remote.name) 的文件"),
                                                to: remote, using: manager.cli)
                            }
                        }
                    }
                    .menuStyle(.button).fixedSize()
                }
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: { Image(systemName: "gearshape") }
                    .help("设置")
                Button("退出") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .frame(width: 320)
    }

    private func show(_ item: SidebarItem?) {
        if let item { navigation.selection = item }
        openWindow(id: "manage")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Picks a folder and starts (or reuses) a recv rule for it.
    private func startReceiving() {
        NSApp.activate(ignoringOtherApps: true)
        guard let url = Panels.chooseDirectory(message: "选择接收文件的目录", prompt: "开始接收") else { return }
        let id: UUID
        if let existing = manager.rules.first(where: { $0.kind == .recv && $0.recvDir == url.path }) {
            id = existing.id
        } else {
            let rule = TunnelRule(name: "收件箱 · \(url.lastPathComponent)", kind: .recv, recvDir: url.path)
            manager.add(rule)
            id = rule.id
        }
        if let runner = manager.runner(id: id), !runner.state.isActive { runner.start() }
        show(.rule(id))
    }
}

private struct MenuRow: View {
    @EnvironmentObject var manager: RuleManager
    @ObservedObject var runner: TunnelRunner
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(state: runner.state).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button(runner.rule.name, action: onOpen).buttonStyle(.plain).lineLimit(1)
                    if let ping = runner.lastPing { PingLabel(ping: ping) }
                    if runner.rule.needsAllowWarning {
                        Image(systemName: "exclamationmark.shield").foregroundStyle(.red).font(.caption)
                    }
                    if let count = manager.inbox[runner.id]?.count, count > 0 {
                        Text("新 \(count)").font(.caption2).foregroundStyle(.blue)
                    }
                }
                details
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { runner.state.isActive },
                set: { _ in manager.toggle(id: runner.id) }
            ))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    @ViewBuilder private var details: some View {
        switch runner.rule.kind {
        case .forward where !runner.listeners.isEmpty:
            ForEach(runner.listeners, id: \.self) { l in
                Button(l.hostPort) { Clipboard.copy(l.hostPort) }
                    .buttonStyle(.link).font(.caption.monospaced()).help("点击复制")
            }
        case .socks where runner.socksAddress != nil:
            Button(runner.socksAddress!) { Clipboard.copy(runner.socksAddress!) }
                .buttonStyle(.link).font(.caption.monospaced()).help("点击复制")
        case .serve where runner.serverAddress != nil, .recv where runner.serverAddress != nil:
            HStack(spacing: 8) {
                Button("复制地址") { Clipboard.copy(runner.serverAddress!) }.buttonStyle(.link).font(.caption)
                if runner.rule.kind == .recv {
                    Button("打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: runner.rule.recvDir)) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        default:
            Text(runner.state.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
