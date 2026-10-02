import SwiftUI
import TailCatCore

/// Saved tailcat keys (`genkey --list`) plus what the app has learned about them.
struct KeysView: View {
    @EnvironmentObject var manager: RuleManager
    @ViewState var keyHelpExpanded = false
    @ViewState private var creating: KeyRole?
    @ViewState private var showWizard = false
    @ViewState private var pendingDelete: String?
    @ViewState private var message: String?
    @ViewState private var busy = false

    init(keyHelpExpanded: Bool = false) {
        _keyHelpExpanded = State(initialValue: keyHelpExpanded)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.tr("密钥")).font(.title2)
                        Spacer()
                        Button { Task { await manager.refreshKeys() } } label: { Image(systemName: "arrow.clockwise") }
                            .help(L10n.tr("刷新"))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Button(L10n.tr("新建服务端密钥…")) { creating = .server }
                            Button(L10n.tr("新建客户端密钥…")) { creating = .client }
                            Button(L10n.tr("DNS 发布向导…")) { showWizard = true }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button(L10n.tr("新建服务端密钥…")) { creating = .server }
                                Button(L10n.tr("新建客户端密钥…")) { creating = .client }
                            }
                            Button(L10n.tr("DNS 发布向导…")) { showWizard = true }
                        }
                    }
                }
                Text(L10n.tr("服务端密钥用于共享本机服务；客户端密钥用于连接他人。nodekey: 公钥用于客户端允许列表，SSH 公钥用于 SSH 登录。"))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L10n.tr("密钥与地址有什么关系？"), isExpanded: $keyHelpExpanded) {
                    Text(L10n.tr("服务端密钥可复用身份，但地址也受 DERP 区域影响。长期分享或发布 DNS 时，建议创建密钥时固定区域（--fixed-region）；已有密钥的区域不能在此修改。未指定服务端密钥时使用 default，未指定客户端密钥时使用 client-default。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }

                if !manager.savedKeys.contains("client-default") {
                    missingDefault(L10n.tr("未保存 client-default：未指定客户端密钥时，每次连接都会使用临时身份。若要让对方通过 --allow 固定放行，请创建客户端密钥并把 nodekey: 公钥发给对方。"),
                                   create: L10n.tr("创建 client-default…")) { creating = .client }
                }
                if !manager.savedKeys.contains("default") {
                    missingDefault(L10n.tr("未保存 default：未指定服务端密钥时，每次启动都会使用临时身份并更换地址。"),
                                   create: L10n.tr("创建 default…")) { creating = .server }
                }
                ForEach(orderedKeys, id: \.self) { name in
                    keyRow(name)
                }
            }
            .padding()
        }
        .task { await manager.refreshKeys() }
        .sheet(item: $creating) { role in KeyCreateSheet(role: role) }
        .sheet(isPresented: $showWizard) { DNSWizard() }
        .confirmationDialog(L10n.tr("删除密钥「%@」？", "\(pendingDelete ?? "")"), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.tr("删除"), role: .destructive) { if let name = pendingDelete { delete(name) } }
        } message: {
            Text(deleteWarning(pendingDelete ?? ""))
        }
    }

    /// tailcat picks these names implicitly, so they matter more than the rest and go first.
    private static let implicitKeys = ["client-default", "default"]

    private var orderedKeys: [String] {
        Self.implicitKeys.filter(manager.savedKeys.contains) + manager.savedKeys.filter { !Self.implicitKeys.contains($0) }
    }

    private func missingDefault(_ text: String, create: String, action: @escaping () -> Void) -> some View {
        GroupBox {
            HStack {
                Text(text).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(create, action: action)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyRow(_ name: String) -> some View {
        let meta = manager.keyMeta(name: name) ?? KeyMeta(name: name)
        let usedBy = manager.rules.filter { !$0.kind.isClient && $0.key == name }.map(\.name)
            + manager.remotes.filter { $0.key == name }.map(\.name)
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: meta.effectiveRole == .client ? "person.crop.circle" : "server.rack")
                    Text(name).font(.headline).lineLimit(1).truncationMode(.middle).help(name)
                    switch name {
                    case "client-default": Badge(text: L10n.tr("本机默认客户端身份"), color: .accentColor, systemImage: "checkmark.seal")
                    case "default": Badge(text: L10n.tr("默认服务端身份"), color: .accentColor, systemImage: "checkmark.seal")
                    default: if let role = meta.effectiveRole { Text(role.label).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let region = meta.region { Text(region == "固定区域" || region == "自建 DERP" ? L10n.tr(region) : region).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if meta.effectiveRole != .server {
                        Button(L10n.tr("复制客户端公钥")) { copyPublicKey(name) }.disabled(busy).fixedSize()
                    }
                    Button(L10n.tr("删除…"), role: .destructive) { pendingDelete = name }.fixedSize()
                }
                if let address = meta.address {
                    CopyableText(text: address, font: .caption.monospaced(), secret: true, copyLabel: L10n.tr("复制完整地址"))
                } else if meta.effectiveRole != .client {
                    Text(L10n.tr("地址未知：用此密钥启动一次服务后会记录下来。")).font(.caption).foregroundStyle(.secondary)
                }
                if let pub = meta.publicKey { CopyableText(text: pub, font: .caption.monospaced(), copyLabel: L10n.tr("复制客户端公钥")) }
                if !usedBy.isEmpty {
                    Text(L10n.tr("使用者：%@", usedBy.joined(separator: L10n.tr("、")))).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func deleteWarning(_ name: String) -> String {
        switch name {
        case "default": return L10n.tr("default 是未指定服务端密钥时自动使用的身份。删除后这些服务可能改用临时身份，地址会变化。")
        case "client-default": return L10n.tr("client-default 是未指定客户端密钥时使用的身份。删除后对方 --allow 里的旧公钥将不再匹配。")
        default: return L10n.tr("删除后使用此密钥的地址或公钥将失效，无法恢复。")
        }
    }

    private func copyPublicKey(_ name: String) {
        busy = true
        Task {
            defer { busy = false }
            switch await manager.cli.printpub(key: name) {
            case .success(let pub):
                Clipboard.copy(pub)
                message = L10n.tr("客户端公钥已复制。")
                if !name.isEmpty { manager.recordKey(KeyMeta(name: name, role: .client, publicKey: pub)) }
            case .failure(let e):
                message = Diagnostics.mask(L10n.tr("获取客户端公钥失败：%@", "\(e.message)"))
            }
        }
    }

    private func delete(_ name: String) {
        Task {
            switch await manager.cli.deleteKey(name: name) {
            case .success:
                manager.forgetKey(name: name)
                message = L10n.tr("已删除 %@", "\(name)")
            case .failure(let e):
                message = Diagnostics.mask(L10n.tr("删除密钥失败：%@", "\(e.message)"))
            }
            await manager.refreshKeys()
        }
    }
}

extension KeyRole: Identifiable {
    public var id: String { rawValue }
}

enum RegionMode: String, CaseIterable, Hashable {
    case auto, nearestNow, named, custom

    var label: String {
        switch self {
        case .auto: return L10n.tr("自动（每次启动按延迟选择）")
        case .nearestNow: return L10n.tr("现在选最近区域并固定（--fixed-region）")
        case .named: return L10n.tr("指定区域")
        case .custom: return L10n.tr("自建 DERP 主机名")
        }
    }
}

/// Region fields shared by the key sheet and the DNS wizard.
private struct RegionFields: View {
    @EnvironmentObject var manager: RuleManager
    @Binding var mode: RegionMode
    @Binding var named: String
    @Binding var hosts: String
    var allowAuto = true
    @ViewState private var regions: [DERPRegionInfo] = []
    @ViewState private var loadError: String?

    var body: some View {
        Picker(L10n.tr("DERP 区域"), selection: $mode) {
            ForEach(RegionMode.allCases.filter { allowAuto || $0 != .auto }, id: \.self) { Text($0.label).tag($0) }
        }
        .task(id: mode) { await loadRegionsIfNeeded() }
        Text(L10n.tr("创建密钥时选择区域；已有密钥的区域不能在此修改。长期分享或发布 DNS 时建议固定区域；自动模式每次启动都会按延迟重新选择。"))
            .font(.caption).foregroundStyle(.secondary)
        if mode == .named {
            if regions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let loadError {
                        Text(loadError).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.tr("正在加载区域列表…")).font(.caption).foregroundStyle(.secondary)
                    }
                    TextField(L10n.tr("区域代码"), text: $named, prompt: Text(L10n.tr("如 sfo")))
                }
            } else {
                Picker(L10n.tr("区域"), selection: $named) {
                    ForEach(regions) { r in Text("\(r.code) · \(r.name)").tag(r.code) }
                }
            }
        }
        if mode == .custom {
            TextField(text: $hosts, prompt: Text("derp1.example.com,derp2.example.com")) { Text(L10n.tr("主机名")).font(.body) }
                .font(.body.monospaced())
        }
    }

    private func loadRegionsIfNeeded() async {
        guard mode == .named, regions.isEmpty else { return }
        switch await manager.cli.listRegions() {
        case .success(let list):
            regions = list
            if named.isEmpty, let first = list.first { named = first.code }
        case .failure(let e): loadError = Diagnostics.mask(L10n.tr("无法获取区域列表：%@", "\(e.message)"))
        }
    }
}

private func regionChoice(_ mode: RegionMode, named: String, hosts: String) -> RegionChoice? {
    switch mode {
    case .auto: return .auto
    case .nearestNow: return .nearestNow
    case .named: return named.isEmpty || named.hasPrefix("-") ? nil : .named(named)
    case .custom:
        let h = hosts.replacingOccurrences(of: " ", with: "")
        return h.isEmpty || h.hasPrefix("-") ? nil : .customHosts(h)
    }
}

struct KeyCreateSheet: View {
    @EnvironmentObject var manager: RuleManager
    @Environment(\.dismiss) private var dismiss
    let role: KeyRole

    @ViewState private var name = ""
    @ViewState private var mode: RegionMode = .auto
    @ViewState private var named = ""
    @ViewState private var hosts = ""
    @ViewState private var embed = false
    @ViewState private var psk = true
    @ViewState private var force = false
    @ViewState private var busy = false
    @ViewState private var result: String?
    @ViewState private var error: String?

    init(role: KeyRole, regionMode: RegionMode = .auto, result: String? = nil, error: String? = nil) {
        self.role = role
        _mode = State(initialValue: regionMode)
        _result = State(initialValue: result)
        _error = State(initialValue: error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(role == .server ? L10n.tr("新建服务端密钥") : L10n.tr("新建客户端密钥")).font(.headline)
            Form {
                TextField(L10n.tr("名称"), text: $name, prompt: Text(role == .server ? L10n.tr("如 home、office") : L10n.tr("如 client-laptop")))
                if role == .server {
                    RegionFields(mode: $mode, named: $named, hosts: $hosts)
                    Toggle(L10n.tr("在地址中嵌入 DERP 地图（--embed-derp-map，地址更长但不依赖 DERP map URL）"), isOn: $embed)
                    Toggle(L10n.tr("地址包含预共享密钥（--psk，默认开启）"), isOn: $psk)
                }
                Toggle(L10n.tr("覆盖同名密钥（--force，旧地址/公钥将失效）"), isOn: $force)
            }
            .formStyle(.grouped)
            if let error { Text(Diagnostics.mask(error)).font(.caption).foregroundStyle(.red) }
            if let result {
                Text(role == .server ? L10n.tr("新地址：") : L10n.tr("公钥：")).font(.caption)
                CopyableText(text: result, font: .caption.monospaced(), lineLimit: 3, secret: role == .server)
            }
            HStack {
                Spacer()
                Button(result == nil ? L10n.tr("取消") : L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
                if result == nil {
                    Button(L10n.tr("创建")) { create() }.keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }
        .padding()
        .frame(width: 520)
        .onAppear {
            if name.isEmpty {
                let preferred = role == .server ? "default" : "client-default"
                name = manager.savedKeys.contains(preferred) ? "" : preferred
            }
        }
    }

    private func create() {
        error = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard TailcatCLI.isValidKeyName(trimmed) else { error = L10n.tr("密钥名称只能包含字母、数字、. _ -，不能以 - 或 . 开头，也不能叫 new"); return }
        busy = true
        Task {
            defer { busy = false }
            if role == .server {
                guard let region = regionChoice(mode, named: named, hosts: hosts) else { error = L10n.tr("请填写区域"); return }
                switch await manager.cli.generateServerKey(name: trimmed, region: region, embedDERPMap: embed, psk: psk, force: force) {
                case .success(let addr):
                    result = addr
                    manager.recordKey(KeyMeta(name: trimmed, role: .server, address: addr, region: regionLabel(region)))
                case .failure(let e): error = Diagnostics.mask(e.message)
                }
            } else {
                switch await manager.cli.generateClientKey(name: trimmed, force: force) {
                case .success(let pub):
                    result = pub
                    manager.recordKey(KeyMeta(name: trimmed, role: .client, publicKey: pub))
                case .failure(let e): error = Diagnostics.mask(e.message)
                }
            }
            await manager.refreshKeys()
        }
    }
}

private func regionLabel(_ r: RegionChoice) -> String? {
    switch r {
    case .auto: return nil
    case .nearestNow: return "固定区域"
    case .named(let n): return n
    case .customHosts: return "自建 DERP"
    }
}

/// Publishing an address in DNS makes it public, so the wizard only creates a server that
/// restricts clients (`--allow`) or authenticates them (ssh authorized keys).
struct DNSWizard: View {
    @EnvironmentObject var manager: RuleManager
    @Environment(\.dismiss) private var dismiss

    @ViewState private var keyName = "dns"
    @ViewState private var mode: RegionMode = .nearestNow
    @ViewState private var named = ""
    @ViewState private var hosts = ""
    @ViewState private var embed = true
    @ViewState private var address: String?
    @ViewState private var domain = ""
    @ViewState private var ports = ""
    @ViewState private var allow: Set<String> = []
    @ViewState private var sshKeys = ""
    @ViewState private var useSSH = false
    @ViewState private var busy = false
    @ViewState private var error: String?

    /// `address` skips step 1 (snapshots).
    init(address: String? = nil, domain: String = "", useSSH: Bool = false, error: String? = nil) {
        _address = State(initialValue: address)
        _domain = State(initialValue: domain)
        _useSSH = State(initialValue: useSSH)
        _error = State(initialValue: error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("DNS 发布向导")).font(.headline)
            Text(L10n.tr("把服务端地址写进 DNS TXT 记录后，对方可以直接用域名连接（如 tailcat ssh 域名）。地址因此变成公开信息，所以必须限制可连接的客户端。"))
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Section(L10n.tr("1. 生成固定区域的密钥")) {
                    TextField(L10n.tr("密钥名称"), text: $keyName, prompt: Text(L10n.tr("如 dns"))).disabled(address != nil)
                    RegionFields(mode: $mode, named: $named, hosts: $hosts, allowAuto: false).disabled(address != nil)
                    Toggle(L10n.tr("嵌入 DERP 地图"), isOn: $embed).disabled(address != nil)
                    if address == nil {
                        Button(L10n.tr("生成")) { generate() }.disabled(busy)
                    }
                }
                if let address {
                    Section(L10n.tr("2. 添加 TXT 记录")) {
                        TextField(L10n.tr("域名"), text: $domain, prompt: Text("home.example.com"))
                        let host = domain.isEmpty ? L10n.tr("<域名>") : domain
                        CopyableText(text: "\(host). TXT \"tailcat=\(address)\"", font: .caption.monospaced(), lineLimit: 4, secret: true)
                        CopyableText(text: "tailcat=\(address)", font: .caption.monospaced(), lineLimit: 4, secret: true)
                    }
                    Section(L10n.tr("3. 创建受限的服务")) {
                        TextField(text: $ports, prompt: Text("22 8080")) { Text(L10n.tr("端口 / 服务")).font(.body) }
                            .font(.body.monospaced())
                        Text(L10n.tr("端口和其他服务只对允许列表里的客户端开放；不勾选任何人时，只能开启下面的 SSH。"))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(manager.contacts) { c in
                            Toggle(c.name, isOn: Binding(
                                get: { allow.contains(c.publicKey) },
                                set: { on in if on { allow.insert(c.publicKey) } else { allow.remove(c.publicKey) } }))
                        }
                        if manager.contacts.isEmpty {
                            Text(L10n.tr("通讯录为空：先在“通讯录”添加对方公钥，或使用 SSH 授权公钥。")).font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle(L10n.tr("开启 SSH（用授权公钥认证）"), isOn: $useSSH)
                        if useSSH {
                            TextField(text: $sshKeys, prompt: Text("alice@github, ~/.ssh/authorized_keys")) { Text(L10n.tr("授权公钥来源")).font(.body) }
                                .font(.body.monospaced())
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 440)
            if address != nil && manager.capabilities == nil {
                Text(L10n.tr("正在检测 tailcat 功能，完成后可创建服务规则。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(Diagnostics.mask(error)).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.tr("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                if address != nil {
                    Button(L10n.tr("创建服务规则")) { createRule() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(manager.capabilities == nil || (allow.isEmpty && !(useSSH && !sshKeys.trimmingCharacters(in: .whitespaces).isEmpty)))
                }
            }
        }
        .padding()
        .frame(width: 580)
    }

    private func generate() {
        error = nil
        let name = keyName.trimmingCharacters(in: .whitespaces)
        guard TailcatCLI.isValidKeyName(name) else { error = L10n.tr("密钥名称无效"); return }
        guard let region = regionChoice(mode, named: named, hosts: hosts) else { error = L10n.tr("请填写区域"); return }
        busy = true
        Task {
            defer { busy = false }
            switch await manager.cli.generateServerKey(name: name, region: region, embedDERPMap: embed) {
            case .success(let addr):
                address = addr
                manager.recordKey(KeyMeta(name: name, role: .server, address: addr, region: regionLabel(region)))
            case .failure(let e): error = Diagnostics.mask(e.message)
            }
            await manager.refreshKeys()
        }
    }

    private func createRule() {
        var services = ports.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        if useSSH && !services.contains("ssh") { services.append("ssh") }
        let rule = TunnelRule(
            name: domain.isEmpty ? L10n.tr("DNS 服务") : domain, kind: .serve,
            key: keyName.trimmingCharacters(in: .whitespaces), services: services,
            allow: manager.contacts.map(\.publicKey).filter(allow.contains).joined(separator: ","),
            sshAuthorizedKeys: useSSH ? sshKeys.trimmingCharacters(in: .whitespaces) : "")
        let issues = manager.validateForSave(rule)
        guard issues.isEmpty else { error = issues.map(\.description).joined(separator: L10n.tr("；")); return }
        guard rule.authenticatesEveryClient else {
            error = L10n.tr("未设置允许列表时只能开启 SSH：端口和其他服务会对所有读到 DNS 记录的人开放。")
            return
        }
        guard manager.add(rule) else { error = Diagnostics.mask(manager.loadError ?? L10n.tr("保存失败，请重试。")); return }
        dismiss()
    }
}
