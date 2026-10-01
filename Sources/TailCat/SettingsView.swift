import ServiceManagement
import SwiftUI
import TailCatCore

struct SettingsView: View {
    @EnvironmentObject var manager: RuleManager
    @ViewState private var settings: AppSettings
    private let snapshotMode: Bool
    @ViewState private var customPath = ""
    @ViewState private var derpmapURL = ""
    @ViewState private var verbose = false
    @ViewState private var notifications = true
    @ViewState private var statusLoop = false
    @ViewState private var launchAtLogin = false
    @ViewState private var pathError: String?

    init(settings: AppSettings = AppSettings(), snapshotMode: Bool = false) {
        _settings = State(initialValue: settings)
        self.snapshotMode = snapshotMode
    }

    var body: some View {
        Form {
            Section("tailcat 二进制") {
                LabeledContent("检测到的路径") {
                    Text(manager.binaryPath ?? "未找到").font(.body.monospaced())
                        .foregroundStyle(manager.binaryPath == nil ? .red : .primary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(manager.binaryPath ?? "")
                }
                LabeledContent("版本") { Text(manager.versionText ?? "未知").font(.body.monospaced()) }
                LabeledContent("perf 测速") {
                    Text(manager.capabilities.perf ? "支持" : "当前版本不支持")
                        .foregroundStyle(manager.capabilities.perf ? .primary : .secondary)
                        .help(manager.capabilities.perf ? "" : "安装支持 perf 的 tailcat 版本后，点击“重新检测”。")
                }
                TextField(text: $customPath, prompt: Text("/opt/homebrew/bin/tailcat")) {
                    Text("自定义路径").font(.body)
                }
                .font(.body.monospaced())
                if let pathError { Text(pathError).foregroundStyle(.red).font(.caption) }
                Text("自定义路径留空时自动检测。").font(.caption).foregroundStyle(.secondary)
                Button("重新检测") { applyBinaryPath() }
            }
            Section("全局参数") {
                TextField(text: $derpmapURL, prompt: Text("https://…/derpmap.json")) {
                    Text("DERP map URL").font(.body)
                }
                .font(.body.monospaced())
                Toggle("详细网络日志（--verbose）", isOn: $verbose)
                Text("DERP map URL 留空使用 Tailscale 公共 DERP。修改后，新启动或重启的规则生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("系统") {
                Toggle("失败、重连和收到文件时发送系统通知", isOn: $notifications)
                Toggle("登录时启动", isOn: $launchAtLogin)
                Toggle("服务端显示在线客户端（实验性）", isOn: $statusLoop)
                Text("依赖 tailcat 未文档化的状态输出（TAILCAT_STATUS_LOOP），重启服务后生效；格式变化时自动不显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 540, height: 720)
        .onAppear(perform: load)
        .onChange(of: derpmapURL) { settings.derpmapURL = $0 }
        .onChange(of: verbose) { settings.verbose = $0 }
        .onChange(of: notifications) { settings.notificationsEnabled = $0 }
        .onChange(of: statusLoop) { settings.statusLoopEnabled = $0 }
        .onChange(of: launchAtLogin) { enabled in
            setLaunchAtLogin(enabled)
        }
        // The custom path applies on button / disappear; live typing shouldn't thrash the locator.
        .onDisappear { applyBinaryPath() }
    }

    private func load() {
        customPath = settings.customBinaryPath ?? ""
        derpmapURL = settings.derpmapURL
        verbose = settings.verbose
        notifications = settings.notificationsEnabled
        statusLoop = settings.statusLoopEnabled
        if !snapshotMode { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func applyBinaryPath() {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            settings.customBinaryPath = nil
            pathError = nil
        } else if FileManager.default.isExecutableFile(atPath: trimmed) {
            settings.customBinaryPath = trimmed
            pathError = nil
        } else {
            pathError = "路径不是可执行文件"
            return
        }
        Task { await manager.refreshTailcatInfo() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard !snapshotMode else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
