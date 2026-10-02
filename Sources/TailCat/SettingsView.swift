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
    @ViewState private var language = AppLanguage.system

    init(settings: AppSettings = AppSettings(), snapshotMode: Bool = false, update: UpdateStatus? = nil) {
        _settings = State(initialValue: settings)
        _update = State(initialValue: update)
        self.snapshotMode = snapshotMode
    }

    var body: some View {
        Form {
            Section(L10n.tr("语言")) {
                Picker(L10n.tr("显示语言"), selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                Text(L10n.tr("语言更改将在下次启动 TailCat 时生效。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.tr("tailcat 二进制")) {
                LabeledContent(L10n.tr("检测到的路径")) {
                    Text(manager.binaryPath ?? L10n.tr("未找到")).font(.body.monospaced())
                        .foregroundStyle(manager.binaryPath == nil ? .red : .primary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(manager.binaryPath ?? "")
                }
                LabeledContent(L10n.tr("版本")) { Text(manager.versionText ?? L10n.tr("未知")).font(.body.monospaced()) }
                LabeledContent(L10n.tr("perf 测速与服务端口映射")) {
                    if let capabilities = manager.capabilities {
                        Text(capabilities.perf ? L10n.tr("支持") : L10n.tr("当前版本不支持"))
                            .foregroundStyle(capabilities.perf ? .primary : .secondary)
                            .help(capabilities.perf ? "" : L10n.tr("安装支持 perf 与 8080:80 映射的 tailcat 版本后，点击“重新检测”。"))
                    } else {
                        Text(L10n.tr("检测中…")).foregroundStyle(.secondary)
                    }
                }
                TextField(text: $customPath, prompt: Text("/opt/homebrew/bin/tailcat")) {
                    Text(L10n.tr("自定义路径")).font(.body)
                }
                .font(.body.monospaced())
                if let pathError { Text(pathError).foregroundStyle(.red).font(.caption) }
                Text(L10n.tr("自定义路径留空时自动检测。")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("重新检测")) { applyBinaryPath() }
            }
            Section(L10n.tr("全局参数")) {
                TextField(text: $derpmapURL, prompt: Text("https://…/derpmap.json")) {
                    Text("DERP map URL").font(.body)
                }
                .font(.body.monospaced())
                Toggle(L10n.tr("详细网络日志（--verbose）"), isOn: $verbose)
                Text(L10n.tr("DERP map URL 留空使用 Tailscale 公共 DERP。修改后，新启动或重启的规则生效。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("系统")) {
                Toggle(L10n.tr("失败、重连和收到文件时发送系统通知"), isOn: $notifications)
                Toggle(L10n.tr("登录时启动"), isOn: $launchAtLogin)
                Toggle(L10n.tr("服务端显示在线客户端（实验性）"), isOn: $statusLoop)
                Text(L10n.tr("依赖 tailcat 未文档化的状态输出（TAILCAT_STATUS_LOOP），重启服务后生效；格式变化时自动不显示。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("TailCat 更新")) {
                LabeledContent(L10n.tr("当前版本")) { Text(appVersion).font(.body.monospaced()) }
                HStack {
                    Button(L10n.tr("检查更新")) { Task { await checkForUpdate() } }
                        .disabled(update == .checking)
                    switch update {
                    case .checking?: ProgressView().controlSize(.small)
                    case .upToDate?: Text(L10n.tr("已是最新版本")).foregroundStyle(.secondary)
                    case .available(let version)?:
                        Text(L10n.tr("有新版本 %@", version))
                        Link(L10n.tr("打开下载页"), destination: UpdateCheck.releasesPage)
                    case .failed(let message)?:
                        Text(L10n.tr("检查失败：%@", message)).foregroundStyle(.red).lineLimit(2).help(message)
                    case nil: EmptyView()
                    }
                }
                Text(L10n.tr("只在点击时访问 GitHub 查询最新版本，不会自动联网；新版本需下载 DMG 替换。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 540, height: 720)
        .onAppear(perform: load)
        .onChange(of: language) { settings.language = $0 }
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
        language = settings.language
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
            pathError = L10n.tr("路径不是可执行文件")
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
