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
            ViewThatFits(in: .vertical) {
                rulesContent.fixedSize(horizontal: false, vertical: true)
                ScrollView { rulesContent }
            }
            .frame(maxHeight: 480)
            Divider().padding(.vertical, 4)
            VStack(spacing: 8) {
                HStack {
                    Button(L10n.tr("管理…")) { show(nil) }
                    Button(L10n.tr("接收…")) { startReceiving() }.help(L10n.tr("选择一个目录，开始接收别人发来的文件"))
                    if !manager.remotes.isEmpty {
                        Menu(L10n.tr("发送…")) {
                            ForEach(manager.remotes) { remote in
                                Button(remote.name) {
                                    NSApp.activate(ignoringOtherApps: true)
                                    FileSender.send(Panels.chooseFiles(message: L10n.tr("选择要发送到 %@ 的文件", remote.name)),
                                                    to: remote, using: manager.cli)
                                }
                            }
                        }
                        .menuStyle(.button).fixedSize()
                    }
                    Spacer()
                }
                HStack {
                    Button { show(.help) } label: { Label(L10n.tr("使用说明"), systemImage: "questionmark.circle") }
                        .buttonStyle(.link)
                    Spacer()
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } label: { Image(systemName: "gearshape") }
                        .help(L10n.tr("设置")).accessibilityLabel(L10n.tr("设置"))
                    Button(L10n.tr("退出")) { NSApp.terminate(nil) }.help(L10n.tr("退出 TailCat 并停止所有由它启动的规则"))
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .frame(width: 320)
    }

    private var rulesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if manager.runners.isEmpty {
                Text(L10n.tr("还没有规则，点“管理…”新建")).foregroundStyle(.secondary).padding(12)
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
        }
    }

    private func show(_ item: SidebarItem?) {
        if let item { navigation.selection = item }
        openWindow(id: "manage")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Picks a folder and starts (or reuses) a recv rule for it.
    private func startReceiving() {
        NSApp.activate(ignoringOtherApps: true)
        guard let url = Panels.chooseDirectory(message: L10n.tr("选择接收文件的目录"), prompt: L10n.tr("开始接收")) else { return }
        let id: UUID
        if let existing = manager.rules.first(where: { $0.kind == .recv && $0.recvDir == url.path }) {
            id = existing.id
        } else {
            let rule = TunnelRule(name: L10n.tr("收件箱 · %@", url.lastPathComponent), kind: .recv, recvDir: url.path)
            guard manager.add(rule) else { show(nil); return }
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
                        .help(runner.rule.name)
                    if let ping = runner.lastPing { PingLabel(ping: ping) }
                    if runner.rule.needsAllowWarning {
                        Image(systemName: "exclamationmark.shield").foregroundStyle(.red).font(.caption)
                    }
                    if let count = manager.inbox[runner.id]?.count, count > 0 {
                        Text(L10n.tr("新 %d", count)).font(.caption2).foregroundStyle(.blue)
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
                CopyButton(text: l.hostPort, label: l.hostPort, iconOnly: false)
                    .buttonStyle(.link).font(.caption.monospaced()).help(L10n.tr("点击复制"))
            }
        case .socks where runner.socksAddress != nil:
            CopyButton(text: runner.socksAddress!, label: runner.socksAddress!, iconOnly: false)
                .buttonStyle(.link).font(.caption.monospaced()).help(L10n.tr("点击复制"))
        case .serve where runner.serverAddress != nil, .recv where runner.serverAddress != nil:
            HStack(spacing: 8) {
                CopyButton(text: runner.serverAddress!, label: L10n.tr("复制完整地址"), iconOnly: false)
                    .buttonStyle(.link).font(.caption)
                if runner.rule.kind == .recv {
                    Button(L10n.tr("打开目录")) { NSWorkspace.shared.open(URL(fileURLWithPath: runner.rule.recvDir)) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        default:
            Text(runner.state.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(runner.state.label)
        }
    }
}
