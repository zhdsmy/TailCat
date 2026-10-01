import ServiceManagement
import SwiftUI
import TailCatCore

/// Result of the last manual update check.
enum UpdateStatus: Equatable {
    case checking, upToDate, available(String), failed(String)
}

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
    @ViewState private var update: UpdateStatus?

    init(settings: AppSettings = AppSettings(), snapshotMode: Bool = false, update: UpdateStatus? = nil) {
        _settings = State(initialValue: settings)
        _update = State(initialValue: update)
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
                LabeledContent("perf 测速与服务端口映射") {
                    if let capabilities = manager.capabilities {
                        Text(capabilities.perf ? "支持" : "当前版本不支持")
                            .foregroundStyle(capabilities.perf ? .primary : .secondary)
                            .help(capabilities.perf ? "" : "安装支持 perf 与 8080:80 映射的 tailcat 版本后，点击“重新检测”。")
                    } else {
                        Text("检测中…").foregroundStyle(.secondary)
                    }
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
            Section("TailCat 更新") {
                LabeledContent("当前版本") { Text(appVersion).font(.body.monospaced()) }
                HStack {
                    Button("检查更新") { Task { await checkForUpdate() } }
                        .disabled(update == .checking)
                    switch update {
                    case .checking?: ProgressView().controlSize(.small)
                    case .upToDate?: Text("已是最新版本").foregroundStyle(.secondary)
                    case .available(let version)?:
                        Text("有新版本 \(version)")
                        Link("打开下载页", destination: UpdateCheck.releasesPage)
                    case .failed(let message)?:
                        Text("检查失败：\(message)").foregroundStyle(.red).lineLimit(2).help(message)
                    case nil: EmptyView()
                    }
                }
                Text("只在点击时访问 GitHub 查询最新版本，不会自动联网；新版本需下载 DMG 替换。")
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

    private func checkForUpdate() async {
        update = .checking
        do {
            let newer = try await UpdateCheck.newerRelease(than: appVersion)
            update = newer.map { .available($0.raw) } ?? .upToDate
        } catch {
            update = .failed(error.localizedDescription)
        }
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
