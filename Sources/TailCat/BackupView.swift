import AppKit
import SwiftUI
import TailCatCore
import UniformTypeIdentifiers

struct BackupView: View {
    @EnvironmentObject var manager: RuleManager
    @ViewState private var plan: ConfigurationImport?
    @ViewState private var message: String?
    @ViewState private var failed = false

    init(plan: ConfigurationImport? = nil) { _plan = State(initialValue: plan) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("配置备份")).font(.title2)
                Text(L10n.tr("导出规则、远端和通讯录。备份包含完整访问地址，请妥善保管；不包含 tailcat 私钥、偏好设置或传输记录。"))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.tr("导出配置…")) { export() }
                    Button(L10n.tr("选择备份并预览…")) { preview() }
                }
                if let message {
                    Text(Diagnostics.mask(message)).foregroundStyle(failed ? .red : .secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let plan {
                    importPreview(plan)
                }
            }.padding()
        }
    }

    private func importPreview(_ plan: ConfigurationImport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("将新增 %d 条规则、%d 个远端、%d 位联系人；跳过 %d 个重复项目。",
                         plan.rules.count, plan.remotes.count, plan.contacts.count, plan.skipped)).font(.headline)
            Text(L10n.tr("保留现有配置；标识冲突时创建新项目。导入规则保持停止，自动启动会关闭。请检查本机目录、命令和权限，再手动启动。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("密钥需要在此设备单独配置；相同名称不代表相同身份。"))
                .font(.caption).foregroundStyle(.orange)
            ForEach(plan.rules) { rule in
                DisclosureGroup(Diagnostics.mask(rule.name)) {
                    Text(Diagnostics.mask(rule.cliCommand(remote: (plan.remotes + manager.remotes).first { $0.id == rule.remoteID })))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(plan.remotes) { remote in
                Text(L10n.tr("远端 %@：%@", Diagnostics.mask(remote.name), Diagnostics.mask(remote.address)))
                    .font(.caption).lineLimit(2)
            }
            ForEach(plan.contacts) { contact in
                Text(L10n.tr("联系人：%@", Diagnostics.mask(contact.name))).font(.caption)
            }
            HStack {
                Button(L10n.tr("取消")) { self.plan = nil }
                Button(L10n.tr("导入这些配置")) {
                    failed = !manager.importConfiguration(plan)
                    message = failed
                        ? L10n.tr("导入未完成；已保存的项目会保留，请重新预览后重试。\n%@", manager.loadError ?? "")
                        : L10n.tr("配置已导入。请检查密钥与本机路径，再手动启动规则。")
                    self.plan = nil
                }.disabled(plan.rules.isEmpty && plan.remotes.isEmpty && plan.contacts.isEmpty)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TailCat-backup.json"
        panel.message = L10n.tr("此文件包含访问凭据，不包含私钥。请保存到可信的位置。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try manager.configurationBackup.write(to: url)
            failed = false
            message = L10n.tr("备份已保存到 %@", url.path)
        } catch { failed = true; message = error.localizedDescription }
    }

    private func preview() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            plan = try manager.previewImport(ConfigurationBackup.read(from: url))
            message = nil
            failed = false
        } catch { plan = nil; failed = true; message = String(describing: error) }
    }
}
