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
    ("ssh", L10n.tr("SSH（需授权公钥）"), false),
    ("no-auth-ssh", L10n.tr("SSH 免认证"), true),
    ("exit-node", L10n.tr("出口节点（对方可经本机访问网络）"), true),
    ("all", L10n.tr("全部端口"), true),
    ("perf", L10n.tr("测速服务"), false),
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
    @ViewState var mappingExamplesExpanded = false
    @ViewState private var importError: String?
    @ViewState private var saveError: String?
    @ViewState private var startAfterSave = false
    @ViewState private var advancedExpanded = false
    @ViewState private var execExpanded: Bool
    @ViewState private var focusRequest = 0
    @ViewState private var creatingKey: KeyRole?
    @ViewState private var creatingContact: Contact?
    @FocusState private var focusedField: RuleEditorField?

    init(rule: TunnelRule, isNew: Bool, contacts: [Contact], saveError: String? = nil,
         importError: String? = nil, mappingExamplesExpanded: Bool = false,
         issues: [RuleIssue] = [],
         onSave: @escaping (TunnelRule) -> Bool) {
        _rule = State(initialValue: rule)
        _saveError = State(initialValue: saveError)
        _importError = State(initialValue: importError)
        _mappingExamplesExpanded = State(initialValue: mappingExamplesExpanded)
        _issues = State(initialValue: issues)
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
        _execExpanded = State(initialValue: !rule.execArgs.isEmpty)
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
            ScrollViewReader { reader in
                Form {
                    TextField(L10n.tr("名称"), text: $rule.name, prompt: Text(L10n.tr("给这条规则起个名字")))
                        .focused($focusedField, equals: .name).id(RuleEditorField.name)
                    fieldErrors(.name)
                    switch rule.kind {
                    case .forward: forwardSection
                    case .socks: socksSection
                    case .serve: serveSection
                    case .recv: recvSection
                    }
                    DisclosureGroup(L10n.tr("高级运行设置"), isExpanded: $advancedExpanded) { supervisionSection }
                }
                .formStyle(.grouped)
                .frame(minHeight: 360, idealHeight: rule.kind == .serve ? 600 : 420)
                .onChange(of: focusRequest) { _ in
                    if let issue = issues.first {
                        withAnimation { reader.scrollTo(RuleEditorField.field(for: issue), anchor: .center) }
                    }
                }
            }
            if !issues.isEmpty {
                Button(L10n.tr("请修正 %d 处输入，点击定位首个问题", issues.count)) { focusRequest += 1 }
                    .buttonStyle(.link).foregroundStyle(.red).font(.caption)
            }
            if let saveError {
                Text(Diagnostics.mask(saveError)).foregroundStyle(.red).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let importError {
                Text(Diagnostics.mask(importError)).foregroundStyle(.red).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if isNew && rule.kind == .forward {
                    Button(L10n.tr("从剪贴板导入")) { importClipboard() }
                }
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存")) { save(confirmed: false, start: false) }.keyboardShortcut("s", modifiers: .command)
                    .disabled(rule.kind == .serve && manager.capabilities == nil)
                Button(L10n.tr("保存并启动")) { save(confirmed: false, start: true) }.keyboardShortcut(.defaultAction)
                    .disabled(rule.kind == .serve && manager.capabilities == nil)
            }
        }
        .padding()
        .frame(width: 580)
        .sheet(item: $creatingKey) { role in
            KeyCreateSheet(role: role) { name in rule.key = name }
        }
        .sheet(item: $creatingContact) { contact in
            ContactEditor(contact: contact, isNew: true) { saved in
                guard manager.saveContact(saved) else { return false }
                allowContacts.insert(saved.publicKey)
                return true
            }
        }
        .confirmationDialog(L10n.tr("该服务没有设置允许列表"), isPresented: $confirmRisk) {
            Button(startAfterSave ? L10n.tr("仍然保存并启动") : L10n.tr("仍然保存"), role: .destructive) { save(confirmed: true) }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("免认证 SSH、exec、出口节点和全部端口会把本机能力交给任何拿到地址的人。建议在“允许的客户端”里至少选一个联系人。"))
        }
    }

    private var title: String {
        switch rule.kind {
        case .forward: return isNew ? L10n.tr("新增转发") : L10n.tr("编辑转发")
        case .socks: return isNew ? L10n.tr("新增 SOCKS") : L10n.tr("编辑 SOCKS")
        case .serve: return isNew ? L10n.tr("新增服务") : L10n.tr("编辑服务")
        case .recv: return isNew ? L10n.tr("新增收件箱") : L10n.tr("编辑收件箱")
        }
    }

    // MARK: Client kinds

    @ViewBuilder private var destinationPicker: some View {
        Picker(rule.kind == .socks ? L10n.tr("出口远端") : L10n.tr("远端"), selection: $destination) {
            if rule.kind == .socks { Text(L10n.tr("不指定（用 <地址>.tailcat 主机名）")).tag(Destination.none) }
            ForEach(manager.remotes) { remote in Text(remote.name).tag(Destination.remote(remote.id)) }
            Text(L10n.tr("直接输入地址…")).tag(Destination.inline)
        }
        if destination == .inline {
            AddressField(address: $rule.address, focus: $focusedField).id(RuleEditorField.address)
            fieldErrors(.address)
            TextField(L10n.tr("客户端密钥"), text: $rule.key, prompt: Text(L10n.tr("可选，留空用 client-default")))
                .focused($focusedField, equals: .key).id(RuleEditorField.key)
            fieldErrors(.key)
            Button(L10n.tr("创建客户端身份…")) { creatingKey = .client }
            Text(L10n.tr("对方在 --allow 中需要这把客户端密钥的 nodekey: 公钥（可在“密钥”页复制）；SSH 公钥用于 SSH 登录，需另行配置。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("保存时会自动存为一个远端，之后可在“远端”里统一修改。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var forwardSection: some View {
        Section(L10n.tr("目标")) { destinationPicker }
        Section(L10n.tr("端口映射（每行一条）")) {
            MappingEditor(text: $listText, focus: $focusedField).id(RuleEditorField.mappings)
            fieldErrors(.mappings)
            Text(L10n.tr("18080:8080 表示本机 18080 转发到远端 8080。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L10n.tr("更多示例"), isExpanded: $mappingExamplesExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("8080：本机和远端都使用 8080"))
                    Text(L10n.tr("0:8080：本地端口由系统分配，远端使用 8080"))
                    Text(L10n.tr("3306:192.168.1.10:3306：经出口节点连接指定 IP 和端口"))
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            TextField(L10n.tr("监听地址"), text: $rule.bind, prompt: Text("127.0.0.1"))
                .focused($focusedField, equals: .bind).id(RuleEditorField.bind)
            fieldErrors(.bind)
            Text(L10n.tr("127.0.0.1 仅允许本机访问；0.0.0.0 允许其他设备通过本机网络地址访问。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.tr("启动后在浏览器打开（--open-browser）"), isOn: $rule.openBrowser)
        }
    }

    @ViewBuilder private var socksSection: some View {
        Section(L10n.tr("代理")) {
            destinationPicker
            TextField(text: $rule.socksListen, prompt: Text("127.0.0.1:1080")) { Text(L10n.tr("监听地址")).font(.body) }
                .font(.body.monospaced()).focused($focusedField, equals: .listen).id(RuleEditorField.listen)
            fieldErrors(.listen)
            Text(L10n.tr("127.0.0.1 仅允许本机访问；0.0.0.0 允许其他设备通过本机网络地址访问。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("浏览器会把主机名转成小写，而 tc 地址区分大小写：浏览器里只能用出口远端或 server.tailcat；命令行工具可用 <地址>.tailcat。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        Picker(L10n.tr("服务端身份"), selection: $rule.key) {
            Text(manager.savedKeys.contains("default") ? L10n.tr("默认身份（default）") : L10n.tr("默认（未保存 default，使用临时身份）")).tag("")
            Text(L10n.tr("临时身份（每次启动更换地址）")).tag("new")
            ForEach(serverKeyChoices, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        Button(L10n.tr("创建服务端身份…")) { creatingKey = .server }
            .id(RuleEditorField.key)
        fieldErrors(.key)
        if (rule.key == "new" || (rule.key.isEmpty && !manager.savedKeys.contains("default"))) && rule.autoRestart {
            Text(L10n.tr("使用临时身份时，进程每次重启（含自动重启）地址都会变化，需要重新发给对方。"))
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(L10n.tr("服务端密钥用于复用身份；长期分享或发布 DNS 时，建议创建密钥时固定 DERP 区域（--fixed-region）。已有密钥的区域不能在此修改。"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var serveSection: some View {
        Section(L10n.tr("身份")) {
            keyPicker
            Toggle(L10n.tr("对外显示完整地址（--full-address，含 DERP 信息）"), isOn: $rule.fullAddress)
        }
        Section(L10n.tr("端口与映射（每行一条，可选）")) {
            TextEditor(text: $listText).font(.body.monospaced()).frame(height: 60)
                .focused($focusedField, equals: .services).id(RuleEditorField.services)
            fieldErrors(.services)
            if manager.capabilities == nil {
                Text(L10n.tr("正在检测 tailcat 功能，完成后可保存服务规则。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if manager.capabilities?.serveMappings == true {
                Text(L10n.tr("如 22、8000-8999、8080:80（隧道 8080 → 本机 80）、5555:192.168.1.10:5555"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.tr("如 22、8000-8999。当前命令行版本不支持 8080:80 这类端口映射，安装支持此功能的版本后重新检测。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section(L10n.tr("服务")) {
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
                .disabled(item.name == "perf" && manager.capabilities?.perf != true && !namedServices.contains("perf"))
            }
            if manager.capabilities?.perf == false {
                Text(L10n.tr("当前命令行版本不含测速功能。安装支持此功能的版本后重新检测。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fieldErrors(.ssh).id(RuleEditorField.ssh)
            if namedServices.contains("ssh") || !rule.sshAuthorizedKeys.isEmpty {
                TextField(text: $rule.sshAuthorizedKeys, prompt: Text("alice@github")) { Text(L10n.tr("SSH 授权公钥来源")).font(.body) }
                    .font(.body.monospaced()).focused($focusedField, equals: .ssh)
                Text(L10n.tr("authorized_keys 文件路径、一行公钥，或 用户名@github（取自 github.com/用户名.keys），多个用逗号分隔"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section(L10n.tr("共享目录")) {
            Toggle(L10n.tr("共享一个目录（files 服务）"), isOn: $shareFiles).id(RuleEditorField.files)
            fieldErrors(.files)
            if shareFiles {
                HStack {
                    Text(rule.filesDir.isEmpty ? L10n.tr("未选择") : rule.filesDir)
                        .font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        .help(rule.filesDir)
                    Spacer()
                    Button(L10n.tr("选择…")) {
                        if let url = Panels.chooseDirectory(message: L10n.tr("选择要共享的目录")) { rule.filesDir = url.path }
                    }
                }
                Picker(L10n.tr("权限"), selection: $rule.filesMode) {
                    ForEach(FilesMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if rule.filesMode == .wo || rule.filesMode == .woPlus {
                    Text(L10n.tr("收件箱权限不能浏览或下载目录内容；请为收件箱选择专用目录。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        DisclosureGroup(L10n.tr("执行命令（可选，每行一个参数）"), isExpanded: $execExpanded) {
            TextEditor(text: $execText).font(.body.monospaced()).frame(height: 50)
                .focused($focusedField, equals: .command).id(RuleEditorField.command)
            fieldErrors(.command)
            Text(L10n.tr("第一行是程序（建议绝对路径）。不开 SSH 时作为 exec 服务，连接的输入输出接到该命令；与 SSH 同开时作为强制命令。命令不经 shell。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section(L10n.tr("允许的客户端（--allow）")) {
            Button(L10n.tr("添加联系人…")) { creatingContact = Contact() }.id(RuleEditorField.allow)
            fieldErrors(.allow)
            if manager.contacts.isEmpty {
                Text(L10n.tr("通讯录为空。可在“通讯录”里给对方的公钥起名字。")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            TextField(text: $allowExtra, prompt: Text("nodekey:…, nodekey:…")) { Text(L10n.tr("其他客户端公钥（可选）")).font(.body) }
                .font(.body.monospaced()).focused($focusedField, equals: .allow)
            Text(L10n.tr("填写 nodekey: 公钥，多个用逗号分隔；都留空表示任何拿到地址的人都能连接。SSH 公钥不能用于此列表。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var recvSection: some View {
        Section(L10n.tr("收件箱")) {
            fieldErrors(.files).id(RuleEditorField.files)
            HStack {
                Text(rule.recvDir.isEmpty ? L10n.tr("未选择目录") : rule.recvDir)
                    .font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                    .help(rule.recvDir)
                Spacer()
                Button(L10n.tr("选择…")) {
                    if let url = Panels.chooseDirectory(message: L10n.tr("选择接收文件的目录")) { rule.recvDir = url.path }
                }
            }
            Toggle(L10n.tr("允许接收目录（--accept-dirs）"), isOn: $rule.acceptDirs)
            keyPicker
        }
    }

    @ViewBuilder private var supervisionSection: some View {
        Section(L10n.tr("运行")) {
            Toggle(L10n.tr("退出后自动重启"), isOn: $rule.autoRestart)
            if rule.kind.isClient {
                Toggle(L10n.tr("定时健康检查（tailcat ping）"), isOn: $rule.healthCheck)
                    .disabled(destination == .none)
            }
            Toggle(L10n.tr("App 启动时自动开启"), isOn: $rule.autoStart)
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
            if rule.name.isEmpty { rule.name = L10n.tr("未命名") }
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

    @ViewBuilder private func fieldErrors(_ field: RuleEditorField) -> some View {
        ForEach(issues.filter { RuleEditorField.field(for: $0) == field }.map(\.description), id: \.self) {
            Text(Diagnostics.mask($0)).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save(confirmed: Bool, start: Bool? = nil) {
        if let start { startAfterSave = start }
        saveError = nil
        let c = candidate()
        issues = manager.validateForSave(c)
        guard issues.isEmpty else {
            if let first = issues.first {
                let field = RuleEditorField.field(for: first)
                if field == .command { execExpanded = true }
                focusedField = field
                focusRequest += 1
            }
            return
        }
        if c.needsAllowWarning && !confirmed {
            confirmRisk = true
            return
        }
        guard onSave(c) else {
            saveError = manager.loadError ?? L10n.tr("保存失败，请重试。")
            return
        }
        if startAfterSave, let runner = manager.runner(id: c.id), !runner.state.isActive { runner.start() }
        dismiss()
    }
}

/// Address input with `tailcat parse` preview and `resolve` expansion.
struct AddressField: View {
    @EnvironmentObject var manager: RuleManager
    @Binding var address: String
    private let focus: FocusState<RuleEditorField?>.Binding?
    @FocusState private var ownFocus: RuleEditorField?

    init(address: Binding<String>, focus: FocusState<RuleEditorField?>.Binding? = nil) {
        _address = address
        self.focus = focus
    }
    @ViewState private var summary: String?
    @ViewState private var error: String?
    @ViewState private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(text: $address, prompt: Text("tc… / home.example.com")) { Text(L10n.tr("地址")).font(.body) }
                .font(.body.monospaced()).focused(focus ?? $ownFocus, equals: .address)
                .onSubmit { Task { await refresh() } }
            HStack {
                Spacer()
                Button(L10n.tr("查看地址信息")) { Task { await refresh() } }.fixedSize()
                Button(L10n.tr("转换为 tc 地址")) { Task { await expand() } }.disabled(busy).fixedSize()
            }
            if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !address.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("tc") {
                Text(L10n.tr("转换会用当前 DNS 结果替换域名，之后不会随 DNS 更新；需要动态更新时请保留域名。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary { Text(summary).font(.caption.monospaced()).foregroundStyle(.secondary) }
            if let error { Text(Diagnostics.mask(error)).font(.caption).foregroundStyle(.red) }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        error = nil
        guard !a.isEmpty else { summary = nil; return }
        // DNS names are valid destinations but `parse` only accepts tc addresses.
        guard a.hasPrefix("tc") else { summary = L10n.tr("DNS 名（需有 tailcat= TXT 记录）"); return }
        if let parsed = await manager.cli.parse(address: a) {
            summary = parsed.summary
        } else {
            summary = nil
            error = L10n.tr("查看地址信息失败。请检查 tc 地址后重试。")
        }
    }

    private func expand() async {
        busy = true
        defer { busy = false }
        guard let resolved = await manager.cli.resolve(address: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            summary = nil
            error = L10n.tr("转换失败。请检查输入地址后重试。")
            return
        }
        address = resolved
        await refresh()
    }
}
