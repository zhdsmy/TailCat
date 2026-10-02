import AppKit
import SwiftUI
import TailCatCore

struct TerminalCommandSheet: View {
    @EnvironmentObject var manager: RuleManager
    @Environment(\.dismiss) private var dismiss
    let remote: Remote
    @ViewState private var mode = SSHLauncher.CommandMode.ssh
    @ViewState private var command = ""
    @ViewState private var error: String?

    private var arguments: Result<[String], CLIError> {
        SSHLauncher.commandArguments(remote: remote, mode: mode,
            command: command.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), settings: manager.cli.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("运行命令")).font(.headline)
            Picker(L10n.tr("运行方式"), selection: $mode) {
                Text(L10n.tr("通过 SSH 在远端运行")).tag(SSHLauncher.CommandMode.ssh)
                Text(L10n.tr("通过临时 SOCKS 在本机运行")).tag(SSHLauncher.CommandMode.socks)
            }
            Text(mode == .ssh ? L10n.tr("使用此远端已保存的 SSH 用户和端口；命令在对方设备执行。")
                 : L10n.tr("命令在本机执行，tailcat 为该命令提供临时代理，命令退出后代理结束。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("每行一个参数，第一行是程序。无需添加引号，也不展开本机 shell 变量或管道。"))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $command).font(.body.monospaced()).frame(height: 120)
                .accessibilityLabel(L10n.tr("命令参数"))
            if case .success(let args) = arguments {
                Text(Diagnostics.mask((["tailcat"] + args).map(ShellQuote.quote).joined(separator: " ")))
                    .font(.caption.monospaced()).textSelection(.enabled).lineLimit(4)
                CopyButton(text: (["tailcat"] + args).map(ShellQuote.quote).joined(separator: " "), label: L10n.tr("复制命令"), iconOnly: false)
            }
            if let error { Text(Diagnostics.mask(error)).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("在终端运行…")) { launch() }.keyboardShortcut(.defaultAction)
            }
        }.padding().frame(width: 540)
    }

    private func launch() {
        do {
            let args = try arguments.get()
            guard let exe = manager.cli.executable() else { throw LaunchError.binaryNotFound }
            let url = try SSHLauncher.writeScript(executable: exe, arguments: args)
            guard NSWorkspace.shared.open(url) else {
                try? FileManager.default.removeItem(at: url)
                error = L10n.tr("无法打开终端，请检查 .command 文件的默认打开方式。")
                return
            }
            dismiss()
        } catch { self.error = String(describing: error) }
    }
}
