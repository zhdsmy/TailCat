import AppKit
import Charts
import SwiftUI
import TailCatCore
import UniformTypeIdentifiers

struct RemoteDetail: View {
    @EnvironmentObject var manager: RuleManager
    @EnvironmentObject var navigation: Navigation
    let remote: Remote
    let onEdit: () -> Void
    let onDeleted: () -> Void
    let onNewRule: (TunnelKind) -> Void
    let onShowRule: (UUID) -> Void
    let onBrowse: () -> Void

    @ViewState private var directTimedOut = false
    @ViewState private var sshError: String?
    @ViewState private var showCommand = false
    @ViewState private var confirmDelete = false
    @ViewState private var deleteError: String?

    init(remote: Remote, onEdit: @escaping () -> Void, onDeleted: @escaping () -> Void,
         onNewRule: @escaping (TunnelKind) -> Void, onShowRule: @escaping (UUID) -> Void,
         onBrowse: @escaping () -> Void = {}, deleteError: String? = nil) {
        self.remote = remote
        self.onEdit = onEdit
        self.onDeleted = onDeleted
        self.onNewRule = onNewRule
        self.onShowRule = onShowRule
        self.onBrowse = onBrowse
        _deleteError = State(initialValue: deleteError)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let deleteError {
                    Text(Diagnostics.mask(deleteError)).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                connectivity
                rulesBox
                sshBox
                FileBrowser(identity: remote.identity, remote: remote).id(remote.id)
                PerfPanel(identity: remote.identity).id(remote.id)
            }
            .padding()
        }
        .task(id: remote.id) {
            directTimedOut = false
            let stale = manager.remotePings[remote.id].map { $0.at.timeIntervalSinceNow < -300 } ?? true
            if stale { await manager.pingRemote(id: remote.id) }
        }
        .sheet(isPresented: $showCommand) { TerminalCommandSheet(remote: remote) }
        .confirmationDialog(L10n.tr("删除远端 %@？", remote.name), isPresented: $confirmDelete) {
            Button(L10n.tr("删除"), role: .destructive) {
                deleteError = nil
                if manager.removeRemote(id: remote.id) {
                    onDeleted()
                } else {
                    deleteError = L10n.tr("无法删除远端：%@", manager.loadError ?? L10n.tr("仍有规则在使用此远端"))
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    title
                    Spacer(minLength: 8)
                    actions
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    actions
                }
            }
            CopyableText(text: remote.address, font: .callout.monospaced(), secret: true,
                         copyLabel: L10n.tr("复制完整地址"))
            Text(L10n.tr("“打开网页”访问远端 %@ 端口，可在连接设置中修改。", String(remote.webPort)))
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    clientKeyLabel
                    sshUserLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    clientKeyLabel
                    sshUserLabel
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
            Text(remote.name).font(.title2).lineLimit(2).help(remote.name)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            Button(L10n.tr("打开网页"), action: onBrowse)
                .help(L10n.tr("本地端口会自动选择空闲端口。"))
                .fixedSize()
            Button(L10n.tr("编辑"), action: onEdit).fixedSize()
            let inUse = !manager.rules(usingRemote: remote.id).isEmpty
            Button(L10n.tr("删除"), role: .destructive) { confirmDelete = true }
                .disabled(inUse)
                .help(inUse ? L10n.tr("还有规则在使用这个远端") : "")
                .fixedSize()
        }
    }

    @ViewBuilder private var sshUserLabel: some View {
        if !remote.sshUser.isEmpty {
            Text(L10n.tr("SSH 用户：%@", remote.sshUser)).lineLimit(1).truncationMode(.middle)
                .help(L10n.tr("SSH 用户：%@", remote.sshUser))
        }
    }

    /// Which client identity actually connects: tailcat silently falls back to a throwaway key
    /// when `client-default` does not exist, which breaks servers that use --allow.
    @ViewBuilder private var clientKeyLabel: some View {
        if !remote.key.isEmpty {
            Text(L10n.tr("客户端密钥：%@", remote.key))
                .lineLimit(1).truncationMode(.middle).help(L10n.tr("客户端密钥：%@", remote.key))
        } else if manager.savedKeys.contains("client-default") {
            Text(L10n.tr("客户端密钥：client-default"))
        } else {
            HStack(spacing: 4) {
                Text(L10n.tr("客户端密钥：临时（每次连接换公钥，对方无法用 --allow 放行）"))
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.tr("去创建 client-default")) { navigation.selection = .keys }
                    .buttonStyle(.link).font(.caption).foregroundStyle(.tint)
                    .fixedSize()
            }
        }
    }

    private func probeStatus(pinging: Bool) -> some View {
        HStack(spacing: 8) {
            RemoteStatusDot(status: manager.remotePings[remote.id])
            if let status = manager.remotePings[remote.id] {
                if let result = status.result {
                    PingLabel(ping: result, font: .callout.monospaced())
                } else {
                    Text(L10n.tr("无响应")).foregroundStyle(.red)
                }
                Ago(date: status.at)
            } else if !pinging {
                Text(L10n.tr("尚未检测")).foregroundStyle(.secondary)
            }
            if pinging { ProgressView().controlSize(.small) }
        }
    }

    private func probeActions(pinging: Bool) -> some View {
        HStack(spacing: 8) {
            Button(L10n.tr("测试连接")) { Task { await ping(untilDirect: false) } }
                .disabled(pinging).fixedSize()
            Button(L10n.tr("等待直连")) { Task { await ping(untilDirect: true) } }
                .disabled(pinging)
                .help(L10n.tr("等待直连探测结果；超时不代表远端离线，中继仍可使用。"))
                .fixedSize()
        }
    }

    private var connectivity: some View {
        let pinging = manager.pingingRemotes.contains(remote.id)
        return GroupBox(L10n.tr("连接探测")) {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        probeStatus(pinging: pinging)
                        Spacer(minLength: 8)
                        probeActions(pinging: pinging)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        probeStatus(pinging: pinging)
                        probeActions(pinging: pinging)
                    }
                }
                if let error = manager.remoteProbeErrors[remote.id] {
                    Text(error.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Text(error.recoverySuggestion).font(.caption).foregroundStyle(.secondary)
                    if error.needsBinaryCheck {
                        Button(L10n.tr("重新检测")) { Task { await manager.refreshTailcatInfo() } }
                    } else {
                        Button(L10n.tr("编辑远端"), action: onEdit).buttonStyle(.link)
                    }
                }
                if directTimedOut {
                    Text(L10n.tr("等待结束，未测得直连；超时不代表远端离线，中继仍可使用。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.tr("最近一次探测成功不代表远端的具体服务可用。直连与中继都可使用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var rulesBox: some View {
        GroupBox(L10n.tr("使用该远端的规则")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(manager.runners.filter { $0.rule.remoteID == remote.id }) { runner in
                    RuleLink(runner: runner) { onShowRule(runner.id) }
                }
                HStack {
                    Button(L10n.tr("新建转发…")) { onNewRule(.forward) }.fixedSize()
                    Button(L10n.tr("新建 SOCKS（经此远端出口）…")) { onNewRule(.socks) }.fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sshBox: some View {
        GroupBox("SSH") {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        sshPortField
                        sshActions
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        sshPortField
                        sshActions
                    }
                }
                if let sshError { Text(sshError).font(.caption).foregroundStyle(.red) }
                Button(L10n.tr("运行 SSH / SOCKS 命令…")) { showCommand = true }.buttonStyle(.link)
                Text(L10n.tr("需要对方开放 tailcat 的 SSH 服务，或开放运行系统 sshd 的端口；登录仍需相应的 SSH 授权。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sshPortField: some View {
        HStack {
            Text(L10n.tr("SSH 端口：%@", remote.sshPort.isEmpty ? "22" : remote.sshPort))
                .font(.callout.monospaced()).lineLimit(2)
            Button(L10n.tr("连接设置…"), action: onEdit).buttonStyle(.link)
        }
    }

    private var sshActions: some View {
        HStack(spacing: 8) {
            Button(L10n.tr("打开 SSH…")) { openSSH() }
                .help(L10n.tr("在终端中连接这个远端的 SSH 服务")).fixedSize()
            CopyButton(text: sshCommand(), label: L10n.tr("复制命令"), iconOnly: false)
                .disabled(!SSHLauncher.isValidPort(remote.sshPort))
                .help(L10n.tr(SSHLauncher.isValidPort(remote.sshPort) ? "复制 tailcat SSH 命令" : "端口格式不对"))
        }
    }

    private func ping(untilDirect: Bool) async {
        directTimedOut = false
        let result = await manager.pingRemote(id: remote.id, untilDirect: untilDirect)
        directTimedOut = untilDirect && result == nil
    }

    private func sshArguments() -> [String]? {
        guard SSHLauncher.isValidPort(remote.sshPort) else { sshError = L10n.tr("端口格式不对"); return nil }
        sshError = nil
        return SSHLauncher.arguments(identity: remote.identity, user: remote.sshUser, port: remote.sshPort)
    }

    private func sshCommand() -> String {
        (["tailcat"] + SSHLauncher.arguments(identity: remote.identity, user: remote.sshUser, port: remote.sshPort))
            .map(ShellQuote.quote).joined(separator: " ")
    }

    private func openSSH() {
        guard let args = sshArguments() else { return }
        guard let exe = manager.cli.executable() else { sshError = LaunchError.binaryNotFound.description; return }
        do {
            let script = try SSHLauncher.writeScript(executable: exe, arguments: args)
            NSWorkspace.shared.open(script)
        } catch {
            sshError = L10n.tr("无法创建终端脚本：%@", error.localizedDescription)
        }
    }
}

private struct RuleLink: View {
    @ObservedObject var runner: TunnelRunner
    let action: () -> Void
    var body: some View {
        HStack {
            StatusDot(state: runner.state)
            Button(runner.rule.name, action: action).buttonStyle(.link)
                .lineLimit(2).help(runner.rule.name)
            Text(runner.rule.kind.label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Files

/// `tailcat ls -l` browser with cp upload/download. Works against servers serving ssh or files.
struct FileBrowser: View {
    @EnvironmentObject var manager: RuleManager
    let identity: ClientIdentity

    @ViewState private var path = "."
    @ViewState private var entries: [RemoteFileEntry]?
    @ViewState private var loading = false
    @ViewState private var error: String?
    let remote: Remote
    @EnvironmentObject var navigation: Navigation
    @ViewState private var dropTargeted = false
    @ViewState private var preserveFileMetadata = false
    @ViewState private var downloadDirectory = false
    @ViewState var guidanceExpanded = false

    init(identity: ClientIdentity, remote: Remote? = nil, path: String = ".", entries: [RemoteFileEntry]? = nil,
         loading: Bool = false, error: String? = nil, guidanceExpanded: Bool = false) {
        self.identity = identity
        _path = State(initialValue: path)
        _entries = State(initialValue: entries)
        _loading = State(initialValue: loading)
        _error = State(initialValue: error)
        self.remote = remote ?? Remote(name: L10n.tr("远端"), address: identity.address, key: identity.key)
        _dropTargeted = State(initialValue: false)
        _preserveFileMetadata = State(initialValue: false)
        _guidanceExpanded = State(initialValue: guidanceExpanded)
    }

    private var jobs: [FileTransfer] { manager.transfers.items.filter { $0.remote.id == remote.id } }
    private var isTransferring: Bool { jobs.contains { $0.state.isActive } }

    var body: some View {
        GroupBox(L10n.tr("文件")) {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        pathNavigation
                        Spacer(minLength: 8)
                        listingActions
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        pathNavigation
                        listingActions
                    }
                }
                Toggle(L10n.tr("保留修改时间和权限"), isOn: $preserveFileMetadata)
                    .disabled(isTransferring)
                if loading { ProgressView().controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if remote.filePort != 22 {
                    Text(L10n.tr("文件端口为 %@。当前 tailcat ls 仅支持 22 端口；可直接指定路径传输。", String(remote.filePort)))
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(L10n.tr("远端路径"), text: $path)
                    Toggle(L10n.tr("下载目标是目录"), isOn: $downloadDirectory)
                    Button(L10n.tr("按路径下载…")) { downloadPath() }.disabled(isTransferring || path.isEmpty)
                }
                ForEach(Array(jobs.prefix(2))) { TransferRow(item: $0) }
                if !jobs.isEmpty {
                    Button(L10n.tr("查看所有传输")) { navigation.selection = .transfers }.buttonStyle(.link)
                }
                if let entries {
                    if entries.isEmpty { Text(L10n.tr("空目录")).foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                            if entry.isDirectory {
                                Button { navigate(FileListing.join(path, entry.name)) } label: {
                                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                                }
                                .buttonStyle(.link).help(entry.name)
                            } else {
                                Text(entry.name).lineLimit(1).truncationMode(.middle).help(entry.name)
                            }
                            Spacer()
                            Text(entry.isDirectory ? "" : formatBytes(entry.size))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(entry.modified).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).help(entry.modified)
                            Button(L10n.tr("下载")) { download(entry) }.buttonStyle(.link)
                                .disabled(isTransferring).fixedSize()
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("拖入文件即可发送；浏览和下载需要对方提供可读取的文件服务。"))
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(L10n.tr("无法列出文件？"), isExpanded: $guidanceExpanded) {
                            Text(L10n.tr("请对方确认已开放可读取的文件服务，并允许当前客户端访问。仅接收模式不提供浏览或下载；列出文件使用的 ls 不携带 SSH 公钥，也无法列出需要 SSH 公钥认证的服务。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: dropTargeted ? 2 : 0))
            .onChange(of: jobs.first?.state) { state in
                if state == .succeeded, entries != nil { navigate(path) }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadURLs(providers) { upload($0) }
                return true
            }
        }
    }

    private var pathNavigation: some View {
        HStack(spacing: 6) {
            Button { navigate(FileListing.parent(of: path)) } label: { Image(systemName: "chevron.up") }
                .disabled(path == "." || entries == nil)
                .help(L10n.tr("返回上一级"))
                .fixedSize()
            Text(path == "." ? L10n.tr("/（共享根目录）") : path).font(.callout.monospaced())
                .lineLimit(1).truncationMode(.middle)
                .help(path == "." ? L10n.tr("/（共享根目录）") : path)
        }
    }

    private var listingActions: some View {
        HStack(spacing: 8) {
            Button(L10n.tr(entries == nil ? "列出文件" : "刷新")) { navigate(path) }
                .disabled(loading || remote.filePort != 22).fixedSize()
            Button(L10n.tr("发送文件…")) { upload(Panels.chooseFiles(message: L10n.tr("选择要发送到远端的文件或目录"))) }
                .disabled(isTransferring).fixedSize()
        }
    }

    private func navigate(_ newPath: String) {
        loading = true
        error = nil
        Task {
            defer { loading = false }
            switch await manager.cli.list(identity, path: newPath) {
            case .success(let list):
                path = newPath
                entries = list.sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
            case .failure(let e):
                error = L10n.tr("列出失败：%@", e.message)
            }
        }
    }

    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty, !isTransferring else { return }
        let target = remote.filePort != 22 || entries != nil ? path : ""
        manager.transfers.start(remote: remote, operation: .upload(files: urls, path: target), preserve: preserveFileMetadata)
    }

    private func download(_ entry: RemoteFileEntry) {
        startDownload(path: FileListing.join(path, entry.name), isDirectory: entry.isDirectory)
    }

    private func downloadPath() { startDownload(path: path, isDirectory: downloadDirectory) }

    private func startDownload(path: String, isDirectory: Bool) {
        guard let dir = Panels.chooseDirectory(message: L10n.tr("下载 %@ 到…", path), prompt: L10n.tr("下载")) else { return }
        manager.transfers.start(remote: remote, operation: .download(path: path, isDirectory: isDirectory, destination: dir),
                               preserve: preserveFileMetadata)
    }
}

@MainActor
enum FileSender {
    static func send(_ urls: [URL], to remote: Remote, using manager: RuleManager) {
        guard !urls.isEmpty else { return }
        manager.transfers.start(remote: remote, operation: .upload(files: urls, path: ""))
    }
}

/// Collects file URLs from drag-and-drop providers, then calls back on the main actor.
func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { completion(urls) }
    }
}

// MARK: Perf

struct PerfPanel: View {
    @EnvironmentObject var manager: RuleManager
    let identity: ClientIdentity

    @ViewState private var options = PerfOptions()
    @ViewState private var running = false
    @ViewState private var task: Task<Void, Never>?
    @ViewState private var report: PerfReport?
    @ViewState private var error: String?

    init(identity: ClientIdentity, options: PerfOptions = PerfOptions(), running: Bool = false,
         report: PerfReport? = nil, error: String? = nil) {
        self.identity = identity
        _options = State(initialValue: options)
        _running = State(initialValue: running)
        _task = State(initialValue: nil)
        _report = State(initialValue: report)
        _error = State(initialValue: error)
    }

    var body: some View {
        GroupBox(L10n.tr("测速（tailcat perf）")) {
            if manager.capabilities == nil {
                Text(L10n.tr("正在检测 tailcat 功能…")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if manager.capabilities?.perf == true { panel } else { unsupported }
        }
    }

    private var unsupported: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("当前版本不支持测速。安装支持 perf 的 tailcat 版本后，点击“重新检测”。"))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(L10n.tr("Homebrew 用户可尝试更新：")).foregroundStyle(.secondary)
                    CopyableText(text: "brew upgrade tailcat", font: .callout.monospaced(), copyLabel: L10n.tr("复制更新命令"))
                    Spacer(minLength: 8)
                    recheckButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Homebrew 用户可尝试更新：")).foregroundStyle(.secondary)
                    HStack {
                        CopyableText(text: "brew upgrade tailcat", font: .callout.monospaced(), copyLabel: L10n.tr("复制更新命令"))
                        Spacer(minLength: 8)
                        recheckButton
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            optionsForm.disabled(running)
            HStack {
                Button(L10n.tr(running ? "测速中…" : "开始测速")) { start() }
                    .disabled(running || !options.isValid)
                if running {
                    ProgressView().controlSize(.small)
                    Button(L10n.tr("取消")) { task?.cancel() }.buttonStyle(.link)
                }
                if !options.isValid { Text(L10n.tr("参数不合法")).font(.caption).foregroundStyle(.red) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let report { result(report) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    protocolPicker
                    directionPicker
                }
                VStack(alignment: .leading, spacing: 6) {
                    protocolPicker
                    directionPicker
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    parallelStepper
                    durationStepper
                }
                VStack(alignment: .leading, spacing: 6) {
                    parallelStepper
                    durationStepper
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    bytesField
                    bitrateField
                }
                VStack(alignment: .leading, spacing: 6) {
                    bytesField
                    bitrateField
                }
            }
            Toggle(L10n.tr("允许经 DERP 中继测速（--via-derp，Tailscale 公共中继始终拒绝）"), isOn: $options.viaDERP)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var protocolPicker: some View {
        Picker(L10n.tr("协议"), selection: $options.proto) {
            ForEach(PerfOptions.Proto.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
        }
        .pickerStyle(.segmented).frame(width: 160)
    }

    private var directionPicker: some View {
        Picker(L10n.tr("方向"), selection: $options.direction) {
            ForEach(PerfOptions.Direction.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .frame(width: 240)
    }

    private var parallelStepper: some View {
        Stepper(L10n.tr("并发流 %d", options.parallel), value: $options.parallel, in: 1...16)
    }

    private var durationStepper: some View {
        Stepper(L10n.tr("时长 %ds", options.seconds), value: $options.seconds, in: 1...120)
            .disabled(!options.bytes.isEmpty)
    }

    private var bytesField: some View {
        TextField(L10n.tr("每流字节数（如 100M，可选）"), text: $options.bytes).frame(width: 240)
    }

    private var bitrateField: some View {
        TextField(L10n.tr("每流码率（如 50M，可选）"), text: $options.bitrate).frame(width: 240)
    }

    private var recheckButton: some View {
        Button(L10n.tr("重新检测")) { Task { await manager.refreshTailcatInfo() } }.fixedSize()
    }

    @ViewBuilder private func result(_ report: PerfReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(report.summaryLines, id: \.self) { Text($0).font(.callout.monospaced()) }
        }
        let samples = report.samples
        if !samples.isEmpty {
            Chart(samples) { s in
                LineMark(x: .value(L10n.tr("秒"), s.second), y: .value("Mbit/s", s.mbps))
                    .foregroundStyle(by: .value(L10n.tr("方向"), s.series))
                PointMark(x: .value(L10n.tr("秒"), s.second), y: .value("Mbit/s", s.mbps))
                    .foregroundStyle(by: .value(L10n.tr("方向"), s.series))
                    .symbolSize(12)
            }
            .chartYAxisLabel("Mbit/s")
            .frame(height: 180)
        }
    }

    private func start() {
        running = true
        error = nil
        report = nil
        let opts = options
        task = Task {
            let result = await manager.cli.perf(identity, options: opts)
            running = false
            task = nil
            switch result {
            case .success(let r): report = r
            case .failure(let e):
                if Task.isCancelled { error = L10n.tr("已取消"); return }
                error = e.message.localizedCaseInsensitiveContains("derp")
                    ? L10n.tr("%@\n当前经 DERP 中继。perf 默认拒绝经中继测速；自建中继可勾选“允许经 DERP”，Tailscale 公共中继始终拒绝。", e.message)
                    : e.message
            }
        }
    }
}

// MARK: Editor

struct RemoteEditor: View {
    @EnvironmentObject var manager: RuleManager
    @Environment(\.dismiss) private var dismiss
    @ViewState private var remote: Remote
    let isNew: Bool
    /// Returns false when the remote could not be saved; the sheet then stays open.
    let onSave: (Remote) -> Bool
    @ViewState private var issues: [RemoteIssue] = []
    @ViewState private var saveError: String?
    @ViewState private var creatingKey = false
    @ViewState private var webPortText: String
    @ViewState private var filePortText: String

    init(remote: Remote, isNew: Bool, saveError: String? = nil, onSave: @escaping (Remote) -> Bool) {
        _remote = State(initialValue: remote)
        _webPortText = State(initialValue: String(remote.webPort))
        _filePortText = State(initialValue: String(remote.filePort))
        _saveError = State(initialValue: saveError)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var clientKeys: [String] {
        var names = manager.savedKeys.filter {
            // Keys of unknown role (e.g. made with the CLI under any name) stay selectable.
            $0 != "client-default" && (manager.keyMeta(name: $0) ?? KeyMeta(name: $0)).effectiveRole != .server
        }
        if !remote.key.isEmpty, !names.contains(remote.key) { names.append(remote.key) }
        return names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr(isNew ? "新增远端" : "编辑远端")).font(.headline)
            Form {
                TextField(L10n.tr("名称"), text: $remote.name, prompt: Text(L10n.tr("如 Mac mini、公司 NAS")))
                AddressField(address: $remote.address)
                Picker(L10n.tr("客户端密钥"), selection: $remote.key) {
                    Text(L10n.tr("默认（client-default，未保存则每次临时）")).tag("")
                    ForEach(clientKeys, id: \.self) { Text($0).tag($0) }
                }
                Button(L10n.tr("创建客户端身份…")) { creatingKey = true }
                Text(L10n.tr("对方限制客户端时，请选择已保存的客户端密钥，把它的 nodekey: 公钥交给对方加入允许列表（在“密钥”里复制）。SSH 登录使用单独的 SSH 公钥。"))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(L10n.tr("SSH 用户名"), text: $remote.sshUser, prompt: Text(L10n.tr("可选")))
                TextField(L10n.tr("SSH 端口或出口地址"), text: $remote.sshPort, prompt: Text("22 / 192.168.1.10:22"))
                TextField(L10n.tr("网页端口"), text: $webPortText)
                TextField(L10n.tr("文件端口"), text: $filePortText)
                Text(L10n.tr("文件端口用于上传和下载。当前 tailcat ls 仅支持 22 端口。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            if !issues.isEmpty {
                ForEach(issues.map(\.description), id: \.self) { Text($0).foregroundStyle(.red).font(.caption) }
            }
            if let saveError { Text(Diagnostics.mask(saveError)).foregroundStyle(.red).font(.caption) }
            HStack {
                if isNew {
                    Button(L10n.tr("从剪贴板粘贴地址")) {
                        saveError = nil
                        switch AddressTools.parseForward(Clipboard.string ?? "") {
                        case .success(let imported): imported.apply(to: &remote)
                        case .failure(let error): saveError = error.localizedDescription
                        }
                    }
                }
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存")) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
        .sheet(isPresented: $creatingKey) { KeyCreateSheet(role: .client) { remote.key = $0 } }
    }

    private func save() {
        saveError = nil
        var c = remote
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        c.address = c.address.trimmingCharacters(in: .whitespacesAndNewlines)
        c.sshUser = c.sshUser.trimmingCharacters(in: .whitespaces)
        c.webPort = Int(webPortText.trimmingCharacters(in: .whitespaces)) ?? 0
        c.filePort = Int(filePortText.trimmingCharacters(in: .whitespaces)) ?? 0
        issues = c.validate()
        guard issues.isEmpty else { return }
        guard onSave(c) else {
            saveError = manager.loadError ?? L10n.tr("保存失败")
            return
        }
        dismiss()
    }
}
