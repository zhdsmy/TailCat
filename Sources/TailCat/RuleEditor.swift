import AppKit
import SwiftUI
import TailCatCore

/// Where a client rule's destination comes from.
private enum Destination: Hashable {
    case none
    case remote(UUID)
    /// Typed or pasted address; RuleManager files it under a new Remote on save.
    case inline
}

/// Named serve services offered as toggles. `files` is implied by the shared directory and
/// `exec` by the command, so neither is listed.
private let serviceToggles: [(name: String, label: String, risky: Bool)] = [
    ("ssh", "SSH（需授权公钥）", false),
    ("no-auth-ssh", "SSH 免认证", true),
    ("exit-node", "出口节点（对方可经本机访问网络）", true),
    ("all", "全部端口", true),
    ("perf", "测速服务", false),
]

struct RuleEditor: View {
    @EnvironmentObject var manager: RuleManager
    @Environment(\.dismiss) private var dismiss
    @ViewState private var rule: TunnelRule
    let isNew: Bool
    let onSave: (TunnelRule) -> Bool

    @ViewState private var destination: Destination
    @ViewState private var listText: String
    @ViewState private var execText: String
    @ViewState private var namedServices: Set<String>
    @ViewState private var allowContacts: Set<String>
    @ViewState private var allowExtra: String
    @ViewState private var shareFiles: Bool
    @ViewState private var issues: [RuleIssue] = []
    @ViewState private var confirmRisk = false
    @ViewState private var importError: String?
    @ViewState private var saveError: String?

    init(rule: TunnelRule, isNew: Bool, contacts: [Contact], saveError: String? = nil,
         importError: String? = nil, onSave: @escaping (TunnelRule) -> Bool) {
        _rule = State(initialValue: rule)
        _saveError = State(initialValue: saveError)
        _importError = State(initialValue: importError)
        self.isNew = isNew
        self.onSave = onSave
        let dest: Destination
        if let id = rule.remoteID { dest = .remote(id) }
        else if !rule.address.isEmpty || rule.kind == .forward { dest = .inline }
        else { dest = .none }
        _destination = State(initialValue: dest)

        let services = rule.cleanedServices
        let toggleNames = Set(serviceToggles.map(\.name))
        _namedServices = State(initialValue: Set(services.filter(toggleNames.contains)))
        let rest = services.filter { !toggleNames.contains($0) && $0 != "files" && $0 != "exec" }
        _listText = State(initialValue: (rule.kind == .serve ? rest : rule.mappings).joined(separator: "\n"))
        _execText = State(initialValue: rule.execArgs.joined(separator: "\n"))
        _shareFiles = State(initialValue: !rule.filesDir.isEmpty)

        let known = Set(contacts.map(\.publicKey))
        let entries = TunnelRule.allowEntries(rule.allow)
        _allowContacts = State(initialValue: Set(entries.filter(known.contains)))
        _allowExtra = State(initialValue: entries.filter { !known.contains($0) }.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: rule.kind.systemImage)
                .font(.headline)
            Form {
                TextField("名称", text: $rule.name, prompt: Text("给这条规则起个名字"))
                switch rule.kind {
                case .forward: forwardSection
                case .socks: socksSection
                case .serve: serveSection
                case .recv: recvSection
                }
                supervisionSection
            }
            .formStyle(.grouped)
            .frame(minHeight: 360, idealHeight: rule.kind == .serve ? 600 : 420)
            if !issues.isEmpty {
                VStack(alignment: .leading) {
                    ForEach(issues.map(\.description), id: \.self) { Text($0).foregroundStyle(.red).font(.caption) }
                }
            }
            if let saveError { Text(Diagnostics.mask(saveError)).foregroundStyle(.red).font(.caption) }
            HStack {
                if isNew && rule.kind == .forward {
                    Button("从剪贴板导入") { importClipboard() }
                }
                if let importError { Text(Diagnostics.mask(importError)).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(confirmed: false) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 580)
        .confirmationDialog("该服务没有设置允许列表", isPresented: $confirmRisk) {
            Button("仍然保存", role: .destructive) { save(confirmed: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("免认证 SSH、exec、出口节点和全部端口会把本机能力交给任何拿到地址的人。建议在“允许的客户端”里至少选一个联系人。")
        }
    }

    /// Chinese typography puts a space between CJK and Latin text ("新增 SOCKS", but "新增转发").
    private var title: String {
        let verb = isNew ? "新增" : "编辑"
        let label = rule.kind.label
        return label.first?.isASCII == true ? "\(verb) \(label)" : verb + label
    }

    // MARK: Client kinds

    @ViewBuilder private var destinationPicker: some View {
        Picker(rule.kind == .socks ? "出口远端" : "远端", selection: $destination) {
            if rule.kind == .socks { Text("不指定（用 <地址>.tailcat 主机名）").tag(Destination.none) }
            ForEach(manager.remotes) { remote in Text(remote.name).tag(Destination.remote(remote.id)) }
            Text("直接输入地址…").tag(Destination.inline)
        }
        if destination == .inline {
            AddressField(address: $rule.address)
            TextField("客户端 Key", text: $rule.key, prompt: Text("可选，留空用 client-default"))
            Text("保存时会自动存为一个远端，之后可在“远端”里统一修改。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var forwardSection: some View {
        Section("目标") { destinationPicker }
        Section("端口映射（每行一条）") {
            TextEditor(text: $listText)
                .font(.body.monospaced()).frame(height: 70)
            Text("如 8080、18080:8080、0:8080（本地端口由系统分配）、3306:192.168.1.10:3306（经出口节点）")
                .font(.caption).foregroundStyle(.secondary)
            TextField("监听地址", text: $rule.bind, prompt: Text("127.0.0.1"))
            Toggle("启动后在浏览器打开（--open-browser）", isOn: $rule.openBrowser)
        }
    }

    @ViewBuilder private var socksSection: some View {
        Section("代理") {
            destinationPicker
            TextField(text: $rule.socksListen, prompt: Text("127.0.0.1:1080")) { Text("监听地址").font(.body) }
                .font(.body.monospaced())
            Text("浏览器会把主机名转成小写，而 tc 地址区分大小写：浏览器里只能用出口远端或 server.tailcat；命令行工具可用 <地址>.tailcat。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Server kinds

    private var serverKeyChoices: [String] {
        var names = manager.savedKeys.filter { name in
            name != "default" && (manager.keyMeta(name: name) ?? KeyMeta(name: name)).effectiveRole != .client
        }
        if !rule.key.isEmpty, rule.key != "new", !names.contains(rule.key) { names.append(rule.key) }
        return names
    }

    @ViewBuilder private var keyPicker: some View {
        Picker("服务端身份", selection: $rule.key) {
            Text(manager.savedKeys.contains("default") ? "默认 key（固定地址）" : "默认（未保存 default key，地址每次启动都变）").tag("")
            Text("临时（每次启动都换新地址）").tag("new")
            ForEach(serverKeyChoices, id: \.self) { name in
                if let addr = manager.keyMeta(name: name)?.address {
                    Text("\(name)（\(addr.prefix(12))…）").tag(name)
                } else {
                    Text(name).tag(name)
                }
            }
        }
        if (rule.key == "new" || (rule.key.isEmpty && !manager.savedKeys.contains("default"))) && rule.autoRestart {
            Text("使用临时 key 时，进程每次重启（含自动重启）地址都会变化，需要重新发给对方。可在“密钥”里创建固定 key。")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var serveSection: some View {
        Section("身份") {
            keyPicker
            Toggle("对外显示完整地址（--full-address，含 DERP 信息）", isOn: $rule.fullAddress)
        }
        Section("端口与映射（每行一条，可选）") {
            TextEditor(text: $listText).font(.body.monospaced()).frame(height: 60)
            Text("如 22、8000-8999、8080:80（隧道 8080 → 本机 80）、5555:192.168.1.10:5555")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("服务") {
            ForEach(serviceToggles, id: \.name) { item in
                Toggle(isOn: Binding(
                    get: { namedServices.contains(item.name) },
                    set: { on in if on { namedServices.insert(item.name) } else { namedServices.remove(item.name) } }
                )) {
                    HStack {
                        Text(item.label)
                        if item.risky { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }
                .disabled(item.name == "perf" && !manager.capabilities.perf && !namedServices.contains("perf"))
            }
            if !manager.capabilities.perf {
                Text("perf 测速服务需要比 v0.7.0 更新的 tailcat（brew upgrade tailcat）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if namedServices.contains("ssh") || !rule.sshAuthorizedKeys.isEmpty {
                TextField(text: $rule.sshAuthorizedKeys, prompt: Text("alice@github")) { Text("SSH 授权公钥来源").font(.body) }
                    .font(.body.monospaced())
                Text("authorized_keys 文件路径、一行公钥，或 用户名@github（取自 github.com/用户名.keys），多个用逗号分隔")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("共享目录") {
            Toggle("共享一个目录（files 服务）", isOn: $shareFiles)
            if shareFiles {
                HStack {
                    Text(rule.filesDir.isEmpty ? "未选择" : rule.filesDir)
                        .font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("选择…") {
                        if let url = Panels.chooseDirectory(message: "选择要共享的目录") { rule.filesDir = url.path }
                    }
                }
                Picker("权限", selection: $rule.filesMode) {
                    ForEach(FilesMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        Section("执行命令（可选，每行一个参数）") {
            TextEditor(text: $execText).font(.body.monospaced()).frame(height: 50)
            Text("第一行是程序（建议绝对路径）。不开 SSH 时作为 exec 服务，连接的输入输出接到该命令；与 SSH 同开时作为强制命令。命令不经 shell。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("允许的客户端（--allow）") {
            if manager.contacts.isEmpty {
                Text("通讯录为空。可在“通讯录”里给对方的公钥起名字。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manager.contacts) { contact in
                Toggle(isOn: Binding(
                    get: { allowContacts.contains(contact.publicKey) },
                    set: { on in if on { allowContacts.insert(contact.publicKey) } else { allowContacts.remove(contact.publicKey) } }
                )) {
                    VStack(alignment: .leading) {
                        Text(contact.name)
                        Text(contact.publicKey).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            TextField(text: $allowExtra, prompt: Text("nodekey:…, nodekey:…")) { Text("其他公钥（可选）").font(.body) }
                .font(.body.monospaced())
            Text("多个公钥用逗号分隔。都留空表示任何拿到地址的人都能连接。").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var recvSection: some View {
        Section("收件箱") {
            HStack {
                Text(rule.recvDir.isEmpty ? "未选择目录" : rule.recvDir)
                    .font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("选择…") {
                    if let url = Panels.chooseDirectory(message: "选择接收文件的目录") { rule.recvDir = url.path }
                }
            }
            Toggle("允许接收目录（--accept-dirs）", isOn: $rule.acceptDirs)
            keyPicker
        }
    }

    @ViewBuilder private var supervisionSection: some View {
        Section("运行") {
            Toggle("退出后自动重启", isOn: $rule.autoRestart)
            if rule.kind.isClient {
                Toggle("定时健康检查（tailcat ping）", isOn: $rule.healthCheck)
                    .disabled(destination == .none)
            }
            Toggle("App 启动时自动开启", isOn: $rule.autoStart)
        }
    }

    // MARK: Actions

    private func importClipboard() {
        switch AddressTools.parseForward(Clipboard.string ?? "") {
        case .failure(let error): importError = error.localizedDescription
        case .success(let imported):
            // listText is the live mapping draft; bare-address imports keep it.
            rule.mappings = lines(listText)
            let remoteID = imported.apply(to: &rule, remotes: manager.remotes)
            destination = remoteID.map(Destination.remote) ?? .inline
            listText = rule.mappings.joined(separator: "\n")
            importError = nil
            if rule.name.isEmpty { rule.name = "未命名" }
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func candidate() -> TunnelRule {
        var c = rule
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        c.key = c.key.trimmingCharacters(in: .whitespaces)
        switch c.kind {
        case .forward, .socks:
            switch destination {
            case .remote(let id): c.remoteID = id; c.address = ""; c.key = ""
            case .inline: c.remoteID = nil; c.address = c.address.trimmingCharacters(in: .whitespacesAndNewlines)
            case .none: c.remoteID = nil; c.address = ""; c.key = ""
            }
            if c.kind == .forward { c.mappings = lines(listText) }
            c.bind = c.bind.trimmingCharacters(in: .whitespaces)
            c.socksListen = c.socksListen.trimmingCharacters(in: .whitespaces)
            if destination == .none { c.healthCheck = false }
        case .serve:
            c.services = serviceToggles.map(\.name).filter(namedServices.contains) + lines(listText)
            c.execArgs = lines(execText)
            if !shareFiles { c.filesDir = "" }
            c.sshAuthorizedKeys = c.sshAuthorizedKeys.trimmingCharacters(in: .whitespaces)
            let extra = TunnelRule.allowEntries(allowExtra)
            let picked = manager.contacts.map(\.publicKey).filter(allowContacts.contains)
            c.allow = (picked + extra.filter { !picked.contains($0) }).joined(separator: ",")
        case .recv:
            break
        }
        return c
    }

    private func save(confirmed: Bool) {
        saveError = nil
        let c = candidate()
        issues = c.validate()
        guard issues.isEmpty else { return }
        if c.needsAllowWarning && !confirmed {
            confirmRisk = true
            return
        }
        guard onSave(c) else {
            saveError = manager.loadError ?? "保存失败，请重试。"
            return
        }
        dismiss()
    }
}

/// Address input with `tailcat parse` preview and `resolve` expansion.
struct AddressField: View {
    @EnvironmentObject var manager: RuleManager
    @Binding var address: String
    @ViewState private var summary: String?
    @ViewState private var error: String?
    @ViewState private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(text: $address, prompt: Text("tc… / home.example.com")) { Text("地址").font(.body) }
                    .font(.body.monospaced())
                    .onSubmit { Task { await refresh() } }
                Button("解析") { Task { await refresh() } }
                Button("展开") { Task { await expand() } }.disabled(busy)
            }
            if let summary { Text(summary).font(.caption.monospaced()).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        error = nil
        guard !a.isEmpty else { summary = nil; return }
        // DNS names are valid destinations but `parse` only accepts tc addresses.
        guard a.hasPrefix("tc") else { summary = "DNS 名（需有 tailcat= TXT 记录）"; return }
        if let parsed = await manager.cli.parse(address: a) {
            summary = parsed.summary
        } else {
            summary = nil
            error = "无法解析该地址（可能无效）"
        }
    }

    private func expand() async {
        busy = true
        defer { busy = false }
        guard let resolved = await manager.cli.resolve(address: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "展开失败"
            return
        }
        address = resolved
        await refresh()
    }
}
