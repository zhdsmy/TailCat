import SwiftUI
import TailCatCore

/// Named client public keys, picked from when restricting a server with `--allow`.
struct ContactsView: View {
    @EnvironmentObject var manager: RuleManager
    @ViewState private var editing: Contact?
    @ViewState private var isNew = false
    @ViewState private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.tr("通讯录")).font(.title2)
                    Spacer()
                    Button(L10n.tr("添加联系人…")) {
                        isNew = true
                        var draft = Contact()
                        if let clip = Clipboard.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           Contact.isValidPublicKey(clip) { draft.publicKey = clip }
                        editing = draft
                    }
                }
                Text(L10n.tr("请让对方在 TailCat「密钥」页复制客户端公钥，或运行 tailcat printpub。nodekey: 公钥用于服务的 --allow；SSH 公钥用于 SSH 登录，不能填在这里。"))
                    .font(.caption).foregroundStyle(.secondary)
                if manager.contacts.isEmpty {
                    Text(L10n.tr("还没有联系人。")).foregroundStyle(.secondary)
                }
                TextField(L10n.tr("搜索联系人"), text: $search).textFieldStyle(.roundedBorder)
                ForEach(manager.contacts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { contact in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "person.crop.circle")
                                Text(contact.name).font(.headline).lineLimit(1).truncationMode(.middle).help(contact.name)
                                Spacer()
                                Button(L10n.tr("编辑")) { isNew = false; editing = contact }
                                Button(L10n.tr("删除"), role: .destructive) { manager.removeContact(id: contact.id) }
                            }
                            CopyableText(text: contact.publicKey, font: .caption.monospaced())
                            let servers = manager.rules
                                .filter { TunnelRule.allowEntries($0.allow).contains(contact.publicKey) }.map(\.name)
                            if !servers.isEmpty {
                                Text(L10n.tr("已放行：%@", servers.joined(separator: L10n.tr("、")))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .sheet(item: $editing) { contact in
            ContactEditor(contact: contact, isNew: isNew) { manager.saveContact($0) }
        }
    }
}

struct ContactEditor: View {
    @EnvironmentObject var manager: RuleManager
    @Environment(\.dismiss) private var dismiss
    @ViewState private var contact: Contact
    let isNew: Bool
    let onSave: (Contact) -> Bool
    @ViewState private var error: String?

    init(contact: Contact, isNew: Bool, error: String? = nil, onSave: @escaping (Contact) -> Bool) {
        _contact = State(initialValue: contact)
        _error = State(initialValue: error)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr(isNew ? "添加联系人" : "编辑联系人")).font(.headline)
            Form {
                TextField(L10n.tr("名称"), text: $contact.name, prompt: Text(L10n.tr("如 Alice 的 MacBook")))
                TextField(text: $contact.publicKey, prompt: Text("nodekey:…")) { Text(L10n.tr("对方的客户端公钥")).font(.body) }
                    .font(.body.monospaced())
            }
            .formStyle(.grouped)
            if let error { Text(Diagnostics.mask(error)).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存")) {
                    error = nil
                    var c = contact
                    c.name = c.name.trimmingCharacters(in: .whitespaces)
                    c.publicKey = c.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard c.isValid else { error = L10n.tr("需要名称；客户端公钥应为 nodekey: 加 64 位十六进制"); return }
                    guard onSave(c) else { error = Diagnostics.mask(manager.loadError ?? L10n.tr("保存失败，请重试。")); return }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
    }
}
