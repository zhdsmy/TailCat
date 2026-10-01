import AppKit
import SwiftUI
import TailCatCore

struct RuleDetail: View {
    @EnvironmentObject var manager: RuleManager
    @ObservedObject var runner: TunnelRunner
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onShowRemote: (UUID) -> Void
    var onDuplicate: () -> Void = {}
    @ViewState private var confirmDelete = false
    @ViewState private var logExpanded = false
    @ViewState private var revealAddress = false
    private let showOnlineClients: Bool?

    init(runner: TunnelRunner, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void,
         onShowRemote: @escaping (UUID) -> Void, onDuplicate: @escaping () -> Void = {},
         revealAddress: Bool = false, logExpanded: Bool = false, showOnlineClients: Bool? = nil) {
        _runner = ObservedObject(wrappedValue: runner)
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onShowRemote = onShowRemote
        self.onDuplicate = onDuplicate
        self.showOnlineClients = showOnlineClients
        _logExpanded = State(initialValue: logExpanded)
        _revealAddress = State(initialValue: revealAddress)
    }

    private var rule: TunnelRule { runner.rule }
    private var remote: Remote? { manager.remote(id: rule.remoteID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                badges
                switch rule.kind {
                case .forward: connectionBox; forwardInfo
                case .socks: connectionBox; socksInfo
                case .serve: serverAddressBox; serveInfo; peersBox
                case .recv: serverAddressBox; inboxBox
                }
                logBox
            }
            .padding()
        }
        .confirmationDialog("删除 \(rule.name)？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    // MARK: Common

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    title
                    Spacer(minLength: 8)
                    headerActions
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    headerActions
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    stateLabel
                    pingLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    stateLabel
                    pingLabel
                }
            }
            if case .reconnecting(_, _, let reason) = runner.state {
                Text("上次退出：\(Diagnostics.mask(reason))")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private var title: some View {
        HStack(spacing: 8) {
            StatusDot(state: runner.state)
            Text(rule.name).font(.title2).lineLimit(2).help(rule.name)
            Label(rule.kind.label, systemImage: rule.kind.systemImage)
                .font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) { actionButtons }
    }

    @ViewBuilder private var actionButtons: some View {
        Button(runner.state.isActive ? "停止" : "启动") { manager.toggle(id: runner.id) }.fixedSize()
        Button("编辑", action: onEdit).fixedSize()
        Menu {
            Button("复制为新规则…", action: onDuplicate)
            Button("复制等价 CLI 命令") { Clipboard.copy(rule.cliCommand(remote: remote)) }
            Button("复制诊断信息（地址已打码）") { Clipboard.copy(diagnostics()) }
            Divider()
            Button("删除…", role: .destructive) { confirmDelete = true }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
    }

    private var stateLabel: some View {
        Text(runner.state.label).foregroundStyle(runner.state.color)
            .fixedSize(horizontal: false, vertical: true).help(runner.state.label)
    }

    @ViewBuilder private var pingLabel: some View {
        if let ping = runner.lastPing {
            HStack(spacing: 8) {
                Text("·").foregroundStyle(.secondary)
                PingLabel(ping: ping, font: .callout.monospaced())
                if let at = runner.lastPingAt { Ago(date: at) }
            }
        }
    }

    private struct BadgeItem: Hashable {
        var text: String
        var color: Color
        var icon: String
    }

    @ViewBuilder private var badges: some View {
        let items = badgeItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in Badge(text: item.text, color: item.color, systemImage: item.icon) }
            }
        }
    }

    private var badgeItems: [BadgeItem] {
        var items: [BadgeItem] = []
        if rule.needsAllowWarning {
            items.append(BadgeItem(text: "未设置允许列表：任何拿到地址的人都能使用这些服务", color: .red,
                                   icon: "exclamationmark.shield.fill"))
        }
        for w in runner.warnings { items.append(BadgeItem(text: w, color: .orange, icon: "exclamationmark.triangle.fill")) }
        if runner.serverIdentity == .ephemeral {
            items.append(BadgeItem(text: "临时地址：进程重启后地址会变化", color: .blue, icon: "info.circle.fill"))
        }
        if rule.kind.isClient, rule.remoteID != nil, remote == nil {
            items.append(BadgeItem(text: "引用的远端已不存在，请编辑规则", color: .red, icon: "xmark.octagon.fill"))
        }
        return items
    }

    /// Collapsed while things work: it is diagnostic output that would otherwise dominate the page.
    private var logBox: some View {
        DisclosureGroup(isExpanded: $logExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Addresses stay masked here too; the address box above has the copyable full value.
                    Text(Diagnostics.mask(runner.log.joined(separator: "\n")))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 180)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: runner.log.count) { _ in proxy.scrollTo("end") }
            }
        } label: {
            Text(runner.log.isEmpty ? "日志（暂无）" : "日志（\(runner.log.count) 行）")
        }
        .onAppear { if runner.state.needsAttention { logExpanded = true } }
        .onChange(of: runner.state) { if $0.needsAttention { logExpanded = true } }
    }

    private func diagnostics() -> String {
        Diagnostics.report(appVersion: appVersion, tailcatVersion: manager.versionText, rule: rule,
                           commandLine: rule.cliCommand(remote: remote), state: runner.state.label,
                           lastPing: runner.lastPing, log: runner.log)
    }

    // MARK: Client kinds

    private var connectionBox: some View {
        GroupBox("连接探测") {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        connectionTarget
                        Spacer(minLength: 8)
                        connectionActions
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        connectionTarget
                        connectionActions
                    }
                }
                if remote != nil {
                    Text("“已启动”表示本机规则在运行；探测成功不代表远端的具体服务可用。中继连接也可使用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var connectionTarget: some View {
        if let remote {
            HStack(spacing: 6) {
                Text("远端")
                Button(remote.name) { onShowRemote(remote.id) }
                    .buttonStyle(.link).lineLimit(2).help(remote.name)
            }
        } else {
            Text("未指定出口远端：通过 <地址>.tailcat 主机名访问各服务端")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var connectionActions: some View {
        if remote != nil {
            HStack(spacing: 8) {
                Text(rule.healthCheck ? "定期探测已开启" : "定期探测已关闭")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                Button("测试连接") { Task { await runner.runPing() } }
                    .disabled(runner.pingBusy).fixedSize()
                Button("等待直连") { Task { await runner.runPing(untilDirect: true, timeoutSeconds: 20) } }
                    .disabled(runner.pingBusy)
                    .help("等待直连探测；超时不代表远端离线，中继仍可使用。")
                    .fixedSize()
                if runner.pingBusy { ProgressView().controlSize(.small) }
            }
        }
    }

    private var forwardInfo: some View {
        GroupBox("端口映射") {
            VStack(alignment: .leading, spacing: 6) {
                if runner.listeners.isEmpty {
                    ForEach(rule.cleanedMappings, id: \.self) { m in
                        Text(MappingSpec.parse(m)?.displayLabel ?? m)
                    }
                    Text("监听 \(rule.bind)，启动后显示实际地址").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(runner.listeners, id: \.self) { listener in
                        listenerRow(listener)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func listenerRow(_ listener: ListenerInfo) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                listenerMapping(listener)
                Spacer(minLength: 8)
                listenerActions(listener)
            }
            VStack(alignment: .leading, spacing: 4) {
                listenerMapping(listener)
                listenerActions(listener)
            }
        }
        .controlSize(.small)
    }

    private func listenerMapping(_ listener: ListenerInfo) -> some View {
        HStack(spacing: 6) {
            Text(listener.hostPort).font(.body.monospaced()).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle).help(listener.hostPort)
            Text("→ \(listener.targetLabel)").foregroundStyle(.secondary)
                .lineLimit(2).help(listener.targetLabel)
        }
    }

    @ViewBuilder private func listenerActions(_ listener: ListenerInfo) -> some View {
        HStack(spacing: 8) {
            CopyButton(text: listener.hostPort, label: "复制", iconOnly: false)
            Button("浏览器") {
                if let url = URL(string: "http://\(listener.hostPort)") { NSWorkspace.shared.open(url) }
            }
            .fixedSize()
            if listener.target == "22" || listener.target.hasSuffix(":22") {
                let user = remote?.sshUser ?? ""
                CopyButton(text: "ssh -p \(listener.port) \(user.isEmpty ? "" : user + "@")\(listener.host)",
                           label: "复制 SSH 命令", iconOnly: false)
            }
        }
    }

    private var socksInfo: some View {
        GroupBox("SOCKS 代理") {
            VStack(alignment: .leading, spacing: 8) {
                if let socks = runner.socksAddress {
                    CopyableText(text: socks)
                    HStack {
                        CopyButton(text: "export all_proxy=\(socks)", label: "复制 export all_proxy=…", iconOnly: false)
                        CopyButton(text: "curl -x \(socks) http://server.tailcat/", label: "复制 curl 示例", iconOnly: false)
                    }
                } else {
                    Text("监听 \(rule.socksListen)，启动后显示代理地址").foregroundStyle(.secondary)
                }
                Text("浏览器会把主机名转成小写，而 tc 地址区分大小写：浏览器里只能经出口远端上网或访问 server.tailcat。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Server kinds

    private var serverAddressBox: some View {
        GroupBox("本机地址") {
            VStack(alignment: .leading, spacing: 8) {
                if let address = runner.serverAddress {
                    HStack(alignment: .firstTextBaseline) {
                        CopyableText(text: address, font: .title3.monospaced(), lineLimit: 3, secret: true,
                                     sharedReveal: $revealAddress, copyLabel: "复制完整地址")
                        Spacer()
                        Button { revealAddress.toggle() } label: {
                            Label(revealAddress ? "隐藏地址" : "显示地址", systemImage: revealAddress ? "eye.slash" : "eye")
                        }
                        .controlSize(.small)
                    }
                    switch runner.serverIdentity {
                    case .saved(let name): Text("身份：已保存的服务端密钥「\(name)」").font(.caption).foregroundStyle(.secondary)
                    case .ephemeral: Text("身份：临时服务端密钥（重启后地址会变化）").font(.caption).foregroundStyle(.secondary)
                    case nil: EmptyView()
                    }
                    Text("长期分享或用于 DNS 时，建议固定中继区域。")
                        .font(.caption).foregroundStyle(.secondary)
                    let commands = rule.peerCommands(serverAddress: address)
                    if !commands.isEmpty {
                        Divider()
                        Text("给对方的命令").font(.caption).foregroundStyle(.secondary)
                        ForEach(commands, id: \.self) { cmd in
                            CopyableText(text: cmd, font: .caption.monospaced(), lineLimit: 2,
                                         secret: true, sharedReveal: $revealAddress)
                        }
                    }
                } else if !rule.key.isEmpty, rule.key != "new", let cached = manager.keyMeta(name: rule.key)?.address {
                    Text("未运行。密钥「\(rule.key)」上次记录的地址：").foregroundStyle(.secondary)
                    CopyableText(text: cached, font: .body.monospaced(), lineLimit: 2, secret: true,
                                 copyLabel: "复制完整地址")
                } else {
                    Text(runner.state.isActive ? "等待服务端输出地址…" : "启动后显示地址").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var serveInfo: some View {
        GroupBox("服务") {
            VStack(alignment: .leading, spacing: 4) {
                let services = rule.cleanedServices
                if !services.isEmpty {
                    LabeledContent("服务项") {
                        Text(services.joined(separator: " ")).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !rule.filesDir.isEmpty {
                    LabeledContent("共享目录") {
                        HStack {
                            Text("\(rule.filesDir)（\(rule.filesMode.label)）")
                                .lineLimit(1).truncationMode(.middle).help(rule.filesDir)
                            Button("在 Finder 中显示") { Panels.revealInFinder(URL(fileURLWithPath: rule.filesDir)) }
                                .buttonStyle(.link).fixedSize()
                        }
                    }
                }
                if !rule.cleanedExecArgs.isEmpty {
                    LabeledContent(rule.cleanedServices.contains("ssh") ? "SSH 强制命令" : "exec 命令") {
                        Text(rule.cleanedExecArgs.joined(separator: " "))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                let allow = TunnelRule.allowEntries(rule.allow)
                LabeledContent("允许的客户端") {
                    Text(allow.isEmpty ? "所有人" : allow.map { manager.contactName(forPublicKey: $0) ?? short($0) }.joined(separator: "、"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var peersBox: some View {
        GroupBox("在线客户端（实验性）") {
            VStack(alignment: .leading, spacing: 4) {
                if !(showOnlineClients ?? AppSettings().statusLoopEnabled) {
                    Text("在设置里开启“服务端显示在线客户端”后重启本服务即可显示。").font(.caption).foregroundStyle(.secondary)
                } else if runner.peers.isEmpty {
                    Text(runner.state == .running ? "暂无客户端（每 5 秒刷新）" : "未运行").foregroundStyle(.secondary)
                } else {
                    ForEach(runner.peers) { peer in peerRow(peer) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func peerRow(_ peer: PeerStatus) -> some View {
        let name = manager.contactName(forPublicKey: peer.publicKey) ?? short(peer.publicKey)
        let fullName = manager.contactName(forPublicKey: peer.publicKey) ?? peer.publicKey
        let connection = peer.isDirect ? "直连 \(peer.curAddr)" : "中继 \(peer.relay)"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(name).lineLimit(1).truncationMode(.middle).help(fullName)
                Text(connection).font(.caption).foregroundStyle(peer.isDirect ? .green : .orange)
                    .lineLimit(1).help(connection)
                Spacer(minLength: 8)
                peerTraffic(peer)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).lineLimit(1).truncationMode(.middle).help(fullName)
                    Spacer(minLength: 8)
                    peerTraffic(peer)
                }
                Text(connection).font(.caption).foregroundStyle(peer.isDirect ? .green : .orange)
                    .lineLimit(1).help(connection)
            }
        }
    }

    private func peerTraffic(_ peer: PeerStatus) -> some View {
        Text("↓\(formatBytes(peer.rxBytes)) ↑\(formatBytes(peer.txBytes))")
            .font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
    }

    private var inboxBox: some View {
        GroupBox("收件箱") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(rule.recvDir).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        .help(rule.recvDir)
                    Spacer()
                    Button("在 Finder 中打开") { NSWorkspace.shared.open(URL(fileURLWithPath: rule.recvDir)) }
                }
                if rule.acceptDirs { Text("允许接收目录").font(.caption).foregroundStyle(.secondary) }
                let received = manager.inbox[rule.id] ?? []
                if !received.isEmpty {
                    Divider()
                    HStack {
                        Text("新收到 \(received.count) 项").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("清除记录") { manager.clearInbox(id: rule.id) }
                            .buttonStyle(.link)
                            .help("只清除列表记录，不会删除收件箱中的文件。")
                    }
                    ForEach(received, id: \.self) { name in
                        Button(name) {
                            Panels.revealInFinder(URL(fileURLWithPath: rule.recvDir).appendingPathComponent(name))
                        }
                        .buttonStyle(.link)
                        .lineLimit(1).truncationMode(.middle).help(name)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func short(_ key: String) -> String {
        key.count > 20 ? "\(key.prefix(14))…\(key.suffix(4))" : key
    }
}
