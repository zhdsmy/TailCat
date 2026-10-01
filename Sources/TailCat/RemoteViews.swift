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
    @ViewState private var sshPort = ""
    @ViewState private var sshError: String?
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
                FileBrowser(identity: remote.identity).id(remote.id)
                PerfPanel(identity: remote.identity).id(remote.id)
            }
            .padding()
        }
        .task(id: remote.id) {
            directTimedOut = false
            let stale = manager.remotePings[remote.id].map { $0.at.timeIntervalSinceNow < -300 } ?? true
            if stale { await manager.pingRemote(id: remote.id) }
        }
        .confirmationDialog("删除远端 \(remote.name)？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                deleteError = nil
                if manager.removeRemote(id: remote.id) {
                    onDeleted()
                } else {
                    deleteError = "无法删除远端：\(manager.loadError ?? "仍有规则在使用此远端")"
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "desktopcomputer")
                Text(remote.name).font(.title2)
                Spacer()
                Button("打开网页", action: onBrowse)
                Button("编辑", action: onEdit)
                let inUse = !manager.rules(usingRemote: remote.id).isEmpty
                Button("删除", role: .destructive) { confirmDelete = true }
                    .disabled(inUse)
                    .help(inUse ? "还有规则在使用这个远端" : "")
            }
            CopyableText(text: remote.address, font: .callout.monospaced(), secret: true)
            HStack(spacing: 16) {
                clientKeyLabel
                if !remote.sshUser.isEmpty { Text("SSH 用户：\(remote.sshUser)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Which client identity actually connects: tailcat silently falls back to a throwaway key
    /// when `client-default` does not exist, which breaks servers that use --allow.
    @ViewBuilder private var clientKeyLabel: some View {
        if !remote.key.isEmpty {
            Text("客户端 key：\(remote.key)")
        } else if manager.savedKeys.contains("client-default") {
            Text("客户端 key：client-default")
        } else {
            HStack(spacing: 4) {
                Text("客户端 key：临时（每次连接换公钥，对方无法用 --allow 放行）")
                Button("去创建 client-default") { navigation.selection = .keys }
                    .buttonStyle(.link).font(.caption).foregroundStyle(.tint)
            }
        }
    }

    private var connectivity: some View {
        let pinging = manager.pingingRemotes.contains(remote.id)
        return GroupBox("连接") {
            HStack(spacing: 8) {
                RemoteStatusDot(status: manager.remotePings[remote.id])
                if let status = manager.remotePings[remote.id] {
                    if let result = status.result {
                        PingLabel(ping: result, font: .callout.monospaced())
                    } else {
                        Text("无响应").foregroundStyle(.red)
                    }
                    Ago(date: status.at)
                } else if !pinging {
                    Text("尚未检测").foregroundStyle(.secondary)
                }
                if pinging { ProgressView().controlSize(.small) }
                if directTimedOut { Text("超时内未获得直连").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("测试连接") { Task { await ping(untilDirect: false) } }.disabled(pinging)
                Button("等待直连") { Task { await ping(untilDirect: true) } }.disabled(pinging)
            }
        }
    }

    private var rulesBox: some View {
        GroupBox("使用该远端的规则") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(manager.runners.filter { $0.rule.remoteID == remote.id }) { runner in
                    RuleLink(runner: runner) { onShowRule(runner.id) }
                }
                HStack {
                    Button("新建转发…") { onNewRule(.forward) }
                    Button("新建 SOCKS（经此远端出口）…") { onNewRule(.socks) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sshBox: some View {
        GroupBox("SSH") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("端口（默认 22，经出口节点可填 ip:port）", text: $sshPort)
                        .frame(maxWidth: 260)
                    Button("在终端中打开") { openSSH() }
                    Button("复制命令") { Clipboard.copy(sshCommand()) }
                }
                if let sshError { Text(sshError).font(.caption).foregroundStyle(.red) }
                Text("需要对方 serve 开启 ssh / no-auth-ssh，或在 22 端口运行 sshd。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ping(untilDirect: Bool) async {
        directTimedOut = false
        let result = await manager.pingRemote(id: remote.id, untilDirect: untilDirect)
        directTimedOut = untilDirect && result == nil
    }

    private func sshArguments() -> [String]? {
        guard SSHLauncher.isValidPort(sshPort) else { sshError = "端口格式不对"; return nil }
        sshError = nil
        return SSHLauncher.arguments(identity: remote.identity, user: remote.sshUser, port: sshPort)
    }

    private func sshCommand() -> String {
        (["tailcat"] + (sshArguments() ?? [])).map(ShellQuote.quote).joined(separator: " ")
    }

    private func openSSH() {
        guard let args = sshArguments() else { return }
        guard let exe = manager.cli.executable() else { sshError = LaunchError.binaryNotFound.description; return }
        do {
            let script = try SSHLauncher.writeScript(executable: exe, arguments: args)
            NSWorkspace.shared.open(script)
        } catch {
            sshError = "无法创建终端脚本：\(error.localizedDescription)"
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
    @ViewState private var transfer: String?
    @ViewState private var transferTask: Task<Void, Never>?
    @ViewState private var dropTargeted = false
    @ViewState private var preserveFileMetadata = false

    var body: some View {
        GroupBox("文件") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { navigate(FileListing.parent(of: path)) } label: { Image(systemName: "chevron.up") }
                        .disabled(path == "." || entries == nil)
                    Text(path == "." ? "/（共享根目录）" : path).font(.callout.monospaced()).lineLimit(1)
                    Spacer()
                    Button(entries == nil ? "列出文件" : "刷新") { navigate(path) }.disabled(loading)
                    Button("发送文件…") { upload(Panels.chooseFiles(message: "选择要发送到远端的文件或目录")) }
                        .disabled(transferTask != nil)
                }
                Toggle("保留修改时间和权限", isOn: $preserveFileMetadata)
                    .disabled(transferTask != nil)
                if loading { ProgressView().controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let transfer {
                    HStack {
                        Text(transfer).font(.caption)
                        if transferTask != nil {
                            ProgressView().controlSize(.small)
                            Button("取消") { transferTask?.cancel() }.buttonStyle(.link)
                        }
                    }
                }
                if let entries {
                    if entries.isEmpty { Text("空目录").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                            if entry.isDirectory {
                                Button(entry.name) { navigate(FileListing.join(path, entry.name)) }.buttonStyle(.link)
                            } else {
                                Text(entry.name)
                            }
                            Spacer()
                            Text(entry.isDirectory ? "" : formatBytes(entry.size))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(entry.modified).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Button("下载") { download(entry) }.buttonStyle(.link).disabled(transferTask != nil)
                        }
                    }
                } else {
                    Text("列出文件需要对方 serve 开启 files 或 no-auth-ssh（ls 不带 SSH 公钥，列不出需公钥认证的 ssh）。可把文件拖到这里发送（投递箱只写不可列出）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: dropTargeted ? 2 : 0))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadURLs(providers) { upload($0) }
                return true
            }
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
                error = "列出失败：\(e.message)"
            }
        }
    }

    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty, transferTask == nil else { return }
        let target = entries == nil ? "" : path
        let preserve = preserveFileMetadata
        transfer = "正在发送 \(urls.count) 项…"
        transferTask = Task {
            let result = await manager.cli.upload(identity, files: urls, remotePath: target, preserve: preserve)
            switch result {
            case .success: transfer = "已发送 \(urls.count) 项"
            case .failure(let e): transfer = Task.isCancelled ? "已取消" : "发送失败：\(e.message)"
            }
            transferTask = nil
            if case .success = result, entries != nil { navigate(path) }
        }
    }

    private func download(_ entry: RemoteFileEntry) {
        guard let dir = Panels.chooseDirectory(message: "下载 \(entry.name) 到…", prompt: "下载") else { return }
        let preserve = preserveFileMetadata
        transfer = "正在下载 \(entry.name)…"
        transferTask = Task {
            let result = await manager.cli.download(identity, remotePath: FileListing.join(path, entry.name),
                                                    isDirectory: entry.isDirectory, to: dir, preserve: preserve)
            switch result {
            case .success: transfer = "已下载到 \(dir.path)"
            case .failure(let e): transfer = Task.isCancelled ? "已取消" : "下载失败：\(e.message)"
            }
            transferTask = nil
        }
    }
}

/// Fire-and-forget upload for the menu and sidebar drop targets; the outcome arrives as a notification.
@MainActor
enum FileSender {
    static func send(_ urls: [URL], to remote: Remote, using cli: TailcatCLI) {
        guard !urls.isEmpty else { return }
        Task {
            let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 项"
            switch await cli.upload(remote.identity, files: urls, remotePath: "") {
            case .success: AppNotifications.post(title: remote.name, body: "已发送 \(label)")
            case .failure(let e): AppNotifications.post(title: remote.name, body: "发送 \(label) 失败：\(e.message)")
            }
        }
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

    var body: some View {
        GroupBox("测速（tailcat perf）") {
            if manager.capabilities.perf { panel } else { unsupported }
        }
    }

    private var unsupported: some View {
        HStack {
            Text("当前 tailcat \(manager.tailcatVersion?.description ?? "") 不支持测速，升级后可用：")
                .foregroundStyle(.secondary)
            CopyableText(text: "brew upgrade tailcat", font: .callout.monospaced())
            Spacer()
            Button("重新检测") { Task { await manager.refreshTailcatInfo() } }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            optionsForm.disabled(running)
            HStack {
                Button(running ? "测速中…" : "开始测速") { start() }
                    .disabled(running || !options.isValid)
                if running {
                    ProgressView().controlSize(.small)
                    Button("取消") { task?.cancel() }.buttonStyle(.link)
                }
                if !options.isValid { Text("参数不合法").font(.caption).foregroundStyle(.red) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let report { result(report) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("协议", selection: $options.proto) {
                    ForEach(PerfOptions.Proto.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 160)
                Picker("方向", selection: $options.direction) {
                    ForEach(PerfOptions.Direction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 240)
            }
            HStack {
                Stepper("并发流 \(options.parallel)", value: $options.parallel, in: 1...16)
                Stepper("时长 \(options.seconds)s", value: $options.seconds, in: 1...120)
                    .disabled(!options.bytes.isEmpty)
            }
            HStack {
                TextField("每流字节数（如 100M，可选）", text: $options.bytes).frame(width: 200)
                TextField("每流码率（如 50M，可选）", text: $options.bitrate).frame(width: 200)
            }
            Toggle("允许经 DERP 中继测速（--via-derp，Tailscale 公共中继始终拒绝）", isOn: $options.viaDERP)
        }
    }

    @ViewBuilder private func result(_ report: PerfReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(report.summaryLines, id: \.self) { Text($0).font(.callout.monospaced()) }
        }
        let samples = report.samples
        if !samples.isEmpty {
            Chart(samples) { s in
                LineMark(x: .value("秒", s.second), y: .value("Mbit/s", s.mbps))
                    .foregroundStyle(by: .value("方向", s.series))
                PointMark(x: .value("秒", s.second), y: .value("Mbit/s", s.mbps))
                    .foregroundStyle(by: .value("方向", s.series))
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
                if Task.isCancelled { error = "已取消"; return }
                error = e.message.localizedCaseInsensitiveContains("derp")
                    ? "\(e.message)\n当前经 DERP 中继。perf 默认拒绝经中继测速；自建中继可勾选“允许经 DERP”，Tailscale 公共中继始终拒绝。"
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

    init(remote: Remote, isNew: Bool, saveError: String? = nil, onSave: @escaping (Remote) -> Bool) {
        _remote = State(initialValue: remote)
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
            Text(isNew ? "新增远端" : "编辑远端").font(.headline)
            Form {
                TextField("名称", text: $remote.name, prompt: Text("如 Mac mini、公司 NAS"))
                AddressField(address: $remote.address)
                Picker("客户端 key", selection: $remote.key) {
                    Text("默认（client-default，未保存则每次临时）").tag("")
                    ForEach(clientKeys, id: \.self) { Text($0).tag($0) }
                }
                Text("对方用 --allow 限制客户端时，需要固定的客户端 key，并把它的公钥发给对方（在“密钥”里复制）。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("SSH 用户名", text: $remote.sshUser, prompt: Text("可选"))
            }
            .formStyle(.grouped)
            if !issues.isEmpty {
                ForEach(issues.map(\.description), id: \.self) { Text($0).foregroundStyle(.red).font(.caption) }
            }
            if let saveError { Text(Diagnostics.mask(saveError)).foregroundStyle(.red).font(.caption) }
            HStack {
                if isNew {
                    Button("从剪贴板粘贴地址") {
                        saveError = nil
                        switch AddressTools.parseForward(Clipboard.string ?? "") {
                        case .success(let imported): imported.apply(to: &remote)
                        case .failure(let error): saveError = error.localizedDescription
                        }
                    }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func save() {
        saveError = nil
        var c = remote
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        c.address = c.address.trimmingCharacters(in: .whitespacesAndNewlines)
        c.sshUser = c.sshUser.trimmingCharacters(in: .whitespaces)
        issues = c.validate()
        guard issues.isEmpty else { return }
        guard onSave(c) else {
            saveError = manager.loadError ?? "保存失败"
            return
        }
        dismiss()
    }
}
