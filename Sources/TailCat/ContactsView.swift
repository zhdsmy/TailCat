import SwiftUI
import TailCatCore

/// Named client public keys, picked from when restricting a server with `--allow`.
struct ContactsView: View {
    @EnvironmentObject var manager: RuleManager
    @ViewState private var editing: Contact?
    @ViewState private var isNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("通讯录").font(.title2)
                    Spacer()
                    Button("添加联系人…") {
                        isNew = true
                        var draft = Contact()
                        if let clip = Clipboard.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           Contact.isValidPublicKey(clip) { draft.publicKey = clip }
                        editing = draft
                    }
                }
                Text("对方在自己的 TailCat「密钥」页复制公钥（或运行 tailcat printpub）发给你，在这里起个名字；服务的“允许的客户端”里就能按名字勾选。")
                    .font(.caption).foregroundStyle(.secondary)
                if manager.contacts.isEmpty {
                    Text("还没有联系人。").foregroundStyle(.secondary)
                }
                ForEach(manager.contacts) { contact in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "person.crop.circle")
                                Text(contact.name).font(.headline)
                                Spacer()
                                Button("编辑") { isNew = false; editing = contact }
                                Button("删除", role: .destructive) { manager.removeContact(id: contact.id) }
                            }
                            CopyableText(text: contact.publicKey, font: .caption.monospaced())
                            let servers = manager.rules
                                .filter { TunnelRule.allowEntries($0.allow).contains(contact.publicKey) }.map(\.name)
                            if !servers.isEmpty {
                                Text("已放行：\(servers.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary)
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
    @Environment(\.dismiss) private var dismiss
    @ViewState private var contact: Contact
    let isNew: Bool
    let onSave: (Contact) -> Void
    @ViewState private var error: String?

    init(contact: Contact, isNew: Bool, onSave: @escaping (Contact) -> Void) {
        _contact = State(initialValue: contact)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "添加联系人" : "编辑联系人").font(.headline)
            Form {
                TextField("名称", text: $contact.name, prompt: Text("如 Alice 的 MacBook"))
                TextField(text: $contact.publicKey, prompt: Text("nodekey:…")) { Text("对方公钥").font(.body) }
                    .font(.body.monospaced())
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    var c = contact
                    c.name = c.name.trimmingCharacters(in: .whitespaces)
                    c.publicKey = c.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard c.isValid else { error = "需要名称，公钥应为 nodekey: 加 64 位十六进制"; return }
                    onSave(c)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
    }
}
