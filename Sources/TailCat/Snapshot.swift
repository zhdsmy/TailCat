#if DEBUG
import AppKit
import SwiftUI
import TailCatCore

/// `TailCat --snapshot <dir> [--dark] [--only=prefix] [--language=en|zh-Hans|zh-Hant]` (debug builds only): renders screens with sample
/// data into PNGs and exits, so UI changes can be reviewed without the real app, its data
/// (everything lives in a temp directory, tailcat is a fake script), or screen-recording access.
/// Window chrome, toolbars and the menu bar itself are not part of the images.
@MainActor
enum Snapshot {
    static func run(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: TailCat --snapshot <dir> [--dark] [--only=prefix] [--language=en|zh-Hans|zh-Hant]\n".utf8))
            exit(64)
        }
        let output = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let languageOption = arguments.first { $0.hasPrefix("--language=") }.map { String($0.dropFirst("--language=".count)) }
        L10n.configure(languageOption.flatMap(AppLanguage.init(rawValue:)) ?? .simplifiedChinese)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)
        Task {
            let status: Int32
            do { try await capture(to: output); status = 0 } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                status = 1
            }
            exit(status)
        }
        app.run()
        exit(0)
    }

    private static func capture(to output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = Renderer(output: output)

        let full = try SampleWorld(tailcatInstalled: true)
        defer { full.tearDown() }
        try await full.populate()
        try await capturePopulated(full, renderer)
        try await captureLayoutCases(renderer)

        // Keep detection pending without delaying fake subprocesses or using real user data.
        let pending = try SampleWorld(tailcatInstalled: true)
        defer { pending.tearDown() }
        pending.manager.refreshBinary()
        try await renderer.page("capability-pending-settings", SettingsView(settings: pending.settings, snapshotMode: true), in: pending)
        try await renderer.page("capability-pending-serve", RuleEditor(
            rule: TunnelRule(name: "本机网页", kind: .serve, services: ["8080:80"]), isNew: true, contacts: []) { _ in false }, in: pending)
        try await renderer.page("capability-pending-dns", DNSWizard(address: SampleWorld.serveAddress, domain: "home.example.com", useSSH: true), in: pending)
        try await renderer.page("capability-pending-perf", PerfPanel(identity: ClientIdentity(address: SampleWorld.macMiniAddress))
            .padding().frame(width: 460), in: pending)

        let empty = try SampleWorld(tailcatInstalled: false)
        defer { empty.tearDown() }
        empty.manager.bootstrap()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await renderer.page("empty-menu", MenuContent(), in: empty)
        try await renderer.page("empty-manage", ManageView(), in: empty, size: CGSize(width: 900, height: 520))
        try await renderer.page("empty-settings", SettingsView(settings: empty.settings, snapshotMode: true), in: empty)

        let ready = try SampleWorld(tailcatInstalled: true)
        defer { ready.tearDown() }
        ready.manager.bootstrap()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await renderer.page("empty-ready", ManageView(), in: ready, size: CGSize(width: 900, height: 520))

        let unreadable = try SampleWorld(tailcatInstalled: false)
        defer { unreadable.tearDown() }
        try SecureFile.write(Data(#"{"version":999,"futureItems":[]}"#.utf8),
                             to: unreadable.directory.appendingPathComponent("data/rules.json"))
        unreadable.manager.bootstrap()
        try await renderer.page("storage-load-failed", ManageView(), in: unreadable,
                                size: CGSize(width: 900, height: 520))
    }

    private static func captureLayoutCases(_ renderer: Renderer) async throws {
        let sample = try SampleWorld(tailcatInstalled: true)
        defer { sample.tearDown() }
        try await sample.populate()
        let manager = sample.manager
        for (name, item) in [("forward", SidebarItem.rule(sample.forwardID)), ("serve", .rule(sample.serveID)),
                             ("remote", .remote(sample.macMiniID)), ("keys", .keys), ("contacts", .contacts),
                             ("guide", .help), ("recv", .rule(sample.recvID))] {
            sample.navigation.selection = item
            try await renderer.page("audit-narrow-\(name)", ManageView(), in: sample, size: CGSize(width: 700, height: 480))
        }
        let longName = "用于外出连接的工作设备与共享资料目录-" + String(repeating: "项目归档", count: 8)
        var remote = manager.remote(id: sample.macMiniID)!
        remote.name = longName
        remote.key = String(repeating: "client-laptop-", count: 8)
        remote.sshUser = String(repeating: "remote_user_", count: 6)
        manager.saveRemote(remote)
        var rule = manager.runner(id: sample.forwardID)!.rule
        rule.name = longName
        manager.update(rule)
        manager.saveContact(Contact(name: longName, publicKey: "nodekey:" + String(repeating: "ab12", count: 16)))
        let binary = sample.directory.appendingPathComponent("tailcat")
        let keyList = (["default", "home", "client-default", remote.key]).map(ShellQuote.quote).joined(separator: " ")
        let expandedKeys = try String(contentsOf: binary).replacingOccurrences(of: "printf 'default\\nhome\\n'", with: "printf '%s\\n' \(keyList)")
        try Data(expandedKeys.utf8).write(to: binary)
        manager.recordKey(KeyMeta(name: remote.key, role: .client, publicKey: "nodekey:" + String(repeating: "cd34", count: 16)))
        await manager.refreshKeys()
        for (name, item) in [("forward", SidebarItem.rule(sample.forwardID)), ("remote", .remote(sample.macMiniID)),
                             ("contacts", .contacts)] {
            sample.navigation.selection = item
            try await renderer.page("audit-long-\(name)", ManageView(), in: sample, size: CGSize(width: 700, height: 620))
        }
        try await renderer.page("audit-long-menu", MenuContent(), in: sample)
        try await renderer.page("audit-long-keys", KeysView(keyHelpExpanded: true), in: sample, size: CGSize(width: 470, height: 620))
        let error = L10n.tr("保存失败：%@", L10n.tr("无法写入所选目录。请检查目录权限，并确认外置磁盘已连接。"))
            + String(repeating: L10n.tr("请保留当前配置后重试。"), count: 8)
        try await renderer.page("audit-long-rule-error", RuleEditor(rule: rule, isNew: true, contacts: manager.contacts,
                                                                  saveError: error, importError: error) { _ in false }, in: sample)
        try await renderer.page("audit-long-remote-error", RemoteEditor(remote: remote, isNew: true, saveError: error) { _ in false }, in: sample)
        try await renderer.page("audit-copy-long", CopyableText(text: String(repeating: "nodekey:12345678", count: 10))
            .padding().frame(width: 320), in: sample)
        try await renderer.page("audit-rule-validation", RuleEditor(rule: rule, isNew: true, contacts: manager.contacts,
            issues: [.emptyName, .invalidAddress, .invalidMapping(String(repeating: "invalid-port-", count: 8)), .invalidBind]) { _ in false }, in: sample)
        var shared = manager.runner(id: sample.serveID)!.rule
        shared.filesDir = "/Users/me/Shared/" + String(repeating: "Project-Archive/", count: 12)
        shared.filesMode = .woPlus
        shared.execArgs = ["/usr/bin/env", "example-command", String(repeating: "long-argument-", count: 12)]
        try await renderer.page("audit-long-shared-directory", RuleEditor(rule: shared, isNew: false, contacts: manager.contacts) { _ in true }, in: sample)
        var receiver = manager.runner(id: sample.recvID)!.rule
        receiver.recvDir = shared.filesDir
        try await renderer.page("audit-long-recv-directory", RuleEditor(rule: receiver, isNew: false, contacts: manager.contacts) { _ in true }, in: sample)
        var mapped = manager.runner(id: sample.serveID)!.rule
        mapped.services += ["8080:80"]
        try await renderer.page("audit-serve-mapping-unsupported", RuleEditor(rule: mapped, isNew: false, contacts: manager.contacts,
            issues: [.serveMappingUnsupported("8080:80")]) { _ in false }, in: sample)
        try await renderer.page("audit-contact-error", ContactEditor(contact: Contact(name: longName), isNew: true, error: error) { _ in false }, in: sample)
        try await renderer.page("audit-key-created", KeyCreateSheet(role: .server, result: SampleWorld.serveAddress), in: sample)
        try await renderer.page("audit-key-error", KeyCreateSheet(role: .client, error: error), in: sample)
        try await renderer.page("audit-key-region-error", KeyCreateSheet(role: .server, regionMode: .named), in: sample)
        try await renderer.page("audit-key-custom-region", KeyCreateSheet(role: .server, regionMode: .custom), in: sample)
        try await renderer.page("audit-dns-ssh-error", DNSWizard(address: SampleWorld.serveAddress, domain: "home.example.com", useSSH: true, error: error), in: sample)

        let identity = remote.identity
        let entries = [RemoteFileEntry(mode: "drwxr-xr-x", size: 96, modified: "Sep 30 09:12", name: longName, isDirectory: true),
                       RemoteFileEntry(mode: "-rw-r--r--", size: 1_048_576, modified: "Sep 29 22:40", name: longName + ".txt", isDirectory: false)]
        try await renderer.page("audit-file-list", ScrollView { FileBrowser(identity: identity, path: shared.filesDir, entries: entries).padding() },
                                in: sample, size: CGSize(width: 460, height: 420))
        try await renderer.page("audit-file-transfer", ScrollView { FileBrowser(identity: identity, loading: true, error: error, transfer: L10n.tr("正在下载 %@…", longName + ".txt"), transferRunning: true).padding() },
                                in: sample, size: CGSize(width: 460, height: 420))
        try await renderer.page("audit-file-empty", FileBrowser(identity: identity, entries: []).padding().frame(width: 460), in: sample)
        try await renderer.page("audit-copy-revealed", CopyableText(text: "tcLONG" + String(repeating: "q7Xk2PzR", count: 100), lineLimit: 3,
            secret: true, sharedReveal: .constant(true)).padding().frame(width: 460), in: sample)

        let failed = TunnelRunner(rule: rule, config: RunnerConfig(launch: { _ in throw CLIError(error) }, probe: { _, _, _ in nil }))
        failed.start()
        defer { failed.stop() }
        try await renderer.page("audit-failed-reason", RuleDetail(runner: failed, onEdit: {}, onDelete: {}, onShowRemote: { _ in }),
                                in: sample, size: CGSize(width: 470, height: 620))

        shared.services = ["all"]
        shared.allow = ""
        let serverLines = ["# 🐈 Server listening with saved key \"default\": \(SampleWorld.serveAddress)",
                           "# ⚠️ WARNING: 任何持有地址的人都可访问此服务。" + String(repeating: "请检查所有开放的端口以及允许的客户端。", count: 4),
                           #"status = {"Peer":{"nodekey:ab12":{"PublicKey":"nodekey:ab12","CurAddr":"192.168.1.20:41641","RxBytes":1048576,"TxBytes":2048576},"nodekey:cd34":{"PublicKey":"nodekey:cd34","Relay":"example-region","RxBytes":9048576,"TxBytes":6048576}}}"#]
        let serverScript = serverLines.map { "echo \(ShellQuote.quote($0)) >&2" }.joined(separator: "; ") + "; exec sleep 120"
        let server = TunnelRunner(rule: shared, config: RunnerConfig(launch: { _ in
            LaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", serverScript])
        }, probe: { _, _, _ in nil }))
        server.start()
        defer { server.stop() }
        try await renderer.page("audit-server-details", RuleDetail(runner: server, onEdit: {}, onDelete: {}, onShowRemote: { _ in },
                                                                    revealAddress: true, showOnlineClients: true),
                                in: sample, size: CGSize(width: 470, height: 620))

        let inbox = URL(fileURLWithPath: manager.runner(id: sample.recvID)!.rule.recvDir)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        manager.runner(id: sample.recvID)!.start()
        try await sample.waitUntil { manager.runner(id: sample.recvID)?.state == .running }
        try Data("sample".utf8).write(to: inbox.appendingPathComponent(longName + ".txt"))
        try await sample.waitUntil { !(manager.inbox[sample.recvID] ?? []).isEmpty }
        sample.navigation.selection = .rule(sample.recvID)
        try await renderer.page("audit-received-files", ManageView(), in: sample, size: CGSize(width: 700, height: 620))

        for index in 1...20 { manager.add(TunnelRule(name: "项目服务 \(index)", mappings: ["8080:80"])) }
        try await renderer.page("audit-menu-many", MenuContent(), in: sample)

        let perf = try SampleWorld(tailcatInstalled: true, supportsPerf: true)
        defer { perf.tearDown() }
        try await perf.populate()
        try await renderer.page("audit-serve-mapping-supported", RuleEditor(rule: mapped, isNew: false, contacts: perf.manager.contacts) { _ in true }, in: perf)
        let report = PerfReport.decode(#"{"path":{"direct":true,"endpoint":"192.168.1.20:41641","rtt":3000000},"params":{"proto":"udp","dir":"both","streams":4,"length":1200,"interval":1000000000},"clientSent":{"bytes":60000000,"datagrams":50000,"duration":3000000000,"intervals":[{"bytes":10000000},{"bytes":20000000},{"bytes":30000000}]},"serverReceived":{"bytes":58800000,"datagrams":49000,"duration":3000000000,"jitter":1000000},"rtt":{"min":1000000,"avg":3000000,"max":12000000,"count":50}}"#)!
        try await renderer.page("audit-perf-ready", ScrollView { PerfPanel(identity: identity).padding() }, in: perf, size: CGSize(width: 460, height: 420))
        try await renderer.page("audit-perf-result", ScrollView { PerfPanel(identity: identity, report: report).padding() }, in: perf, size: CGSize(width: 460, height: 620))
        try await renderer.page("audit-perf-error", ScrollView { PerfPanel(identity: identity, error: error).padding() }, in: perf, size: CGSize(width: 460, height: 420))
        try await renderer.page("audit-perf-running", ScrollView { PerfPanel(identity: identity, running: true).padding() }, in: perf, size: CGSize(width: 460, height: 420))
    }

    private static func capturePopulated(_ sample: SampleWorld, _ renderer: Renderer) async throws {
        let manager = sample.manager
        func page<V: View>(_ name: String, _ view: V) async throws { try await renderer.page(name, view, in: sample) }
        func manage(_ name: String, _ item: SidebarItem, height: CGFloat) async throws {
            sample.navigation.selection = item
            try await renderer.page(name, ManageView(), in: sample, size: CGSize(width: 900, height: height))
        }

        try await page("menu", MenuContent())
        sample.navigation.selection = nil
        try await renderer.page("manage-none", ManageView(), in: sample, size: CGSize(width: 900, height: 620))
        try await manage("forward", .rule(sample.forwardID), height: 620)
        try await manage("forward-stopped", .rule(sample.stoppedForwardID), height: 620)
        try await manage("forward-failed", .rule(sample.failingID), height: 620)
        try await manage("socks", .rule(sample.socksID), height: 620)
        try await manage("serve", .rule(sample.serveID), height: 900)
        try await manage("remote", .remote(sample.macMiniID), height: 900)
        try await manage("keys", .keys, height: 700)
        try await renderer.page("keys-help", KeysView(keyHelpExpanded: true), in: sample,
                                size: CGSize(width: 670, height: 700))
        try await manage("contacts", .contacts, height: 500)
        try await manage("guide-connect", .help, height: 620)
        for (name, topic) in [("share", UsageGuide.Topic.share), ("files", .files), ("troubleshoot", .troubleshoot)] {
            try await renderer.page("guide-\(name)", UsageGuide(onAddRemote: {}, onNewRule: { _ in }, topic: topic),
                                    in: sample, size: CGSize(width: 670, height: 620))
        }
        try await page("copy-feedback", CopyButton(text: "brew install tailcat", label: L10n.tr("复制安装命令"), copied: true).padding())
        try await renderer.page("file-browser-help", FileBrowser(identity: ClientIdentity(address: SampleWorld.macMiniAddress),
                                                                 guidanceExpanded: true).padding()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                                in: sample, size: CGSize(width: 650, height: 260))
        try await page("settings", SettingsView(settings: sample.settings, snapshotMode: true))
        try await page("settings-update-available", SettingsView(settings: sample.settings, snapshotMode: true,
                                                                 update: .available("v9.9.9")))
        if let rule = manager.runner(id: sample.forwardID)?.rule {
            try await page("editor-forward", RuleEditor(rule: rule, isNew: false, contacts: manager.contacts) { _ in true })
            try await page("editor-forward-examples", RuleEditor(rule: rule, isNew: false, contacts: manager.contacts,
                                                                 mappingExamplesExpanded: true) { _ in true })
            try await page("editor-rule-save-failed", RuleEditor(rule: rule, isNew: false, contacts: manager.contacts,
                                                         saveError: L10n.tr("保存失败：数据文件暂时无法写入，请重试。")) { _ in false })
            try await page("editor-import-failed", RuleEditor(rule: rule.duplicate(), isNew: true, contacts: manager.contacts,
                                                              importError: L10n.tr("命令中包含无效的端口映射")) { _ in true })
            let dataFile = sample.directory.appendingPathComponent("data/rules.json")
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: dataFile.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: dataFile.path) }
            _ = manager.remove(id: rule.id)
            try await manage("rule-delete-failed", .rule(rule.id), height: 660)
            manager.dismissError()
        }
        if let rule = manager.runner(id: sample.serveID)?.rule {
            try await page("editor-serve", RuleEditor(rule: rule, isNew: false, contacts: manager.contacts) { _ in true })
            var shared = rule
            shared.filesDir = "/Users/me/Shared"
            shared.filesMode = .woPlus
            try await page("editor-shared-directory", RuleEditor(rule: shared, isNew: false, contacts: manager.contacts) { _ in true })
        }
        if let remote = manager.remote(id: sample.macMiniID) {
            try await page("editor-remote", RemoteEditor(remote: remote, isNew: false) { _ in true })
            var dnsRemote = remote
            dnsRemote.address = "home.example.com"
            try await page("editor-remote-dns", RemoteEditor(remote: dnsRemote, isNew: false) { _ in true })
            try await page("editor-remote-save-failed", RemoteEditor(remote: remote, isNew: false,
                                                                   saveError: L10n.tr("保存失败：数据文件暂时无法写入，请重试。")) { _ in false })
        }
        let unusedRemote = Remote(name: "备用远端", address: SampleWorld.officeAddress)
        manager.saveRemote(unusedRemote)
        try await page("remote-delete-failed", RemoteDetail(remote: unusedRemote, onEdit: {}, onDeleted: {},
                                                           onNewRule: { _ in }, onShowRule: { _ in },
                                                           deleteError: L10n.tr("无法删除远端：数据文件暂时无法写入，请重试。")))
        try await page("editor-new-socks", RuleEditor(rule: TunnelRule(kind: .socks), isNew: true, contacts: manager.contacts) { _ in true })
        try await page("editor-new-recv", RuleEditor(rule: TunnelRule(kind: .recv), isNew: true, contacts: manager.contacts) { _ in true })
        try await page("key-new-server", KeyCreateSheet(role: .server))
        try await page("key-new-client", KeyCreateSheet(role: .client))
        try await page("dns-wizard", DNSWizard())
        try await page("dns-wizard-published", DNSWizard(address: "tcDNS" + String(repeating: "q7Xk2PzR", count: 10)))
        try await page("contact-editor", ContactEditor(contact: Contact(), isNew: true) { _ in true })
    }
}

@MainActor
private final class Renderer {
    let output: URL
    /// Kept alive until exit: closing a window fires onDisappear side effects (SettingsView writes
    /// the binary path back to UserDefaults).
    private var windows: [NSWindow] = []

    init(output: URL) { self.output = output }

    func page<V: View>(_ name: String, _ view: V, in sample: SampleWorld, size: CGSize? = nil) async throws {
        if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--only=") }),
           !name.hasPrefix(String(option.dropFirst("--only=".count))) { return }
        let root = view
            .environmentObject(sample.manager)
            .environmentObject(sample.navigation)
            .background(Color(nsColor: .windowBackgroundColor))
            // Give SwiftUI the same viewport as the window; otherwise split views can grow
            // their hosting bounds and leave the top of a fixed-size capture outside the bitmap.
            .frame(width: size?.width, height: size?.height)
        let host = NSHostingView(rootView: root)
        let frame = CGRect(origin: .zero, size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        // Let `.task` / `.onAppear` work (auto-ping, key refresh) land before drawing.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        host.layoutSubtreeIfNeeded()
        try save(name, host: host)
        // A form's first viewport does not cover its lower sections. Capture overlapping pages
        // of the main scroll area; nested text editors and the sidebar are not page content.
        if let scroll = scrollViews(in: host).filter({
            !($0.documentView is NSTextView) && $0.contentSize.height > 100
                && $0.contentSize.width > host.bounds.width * 0.5
                && ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 1
        }).max(by: { $0.contentSize.width * $0.contentSize.height < $1.contentSize.width * $1.contentSize.height }),
           let document = scroll.documentView {
            var offset: CGFloat = 0
            for index in 1...12 {
                let end = max(0, document.bounds.height - scroll.contentSize.height)
                guard offset < end else { break }
                offset = min(end, offset + scroll.contentSize.height * 0.85)
                let y = document.isFlipped ? offset : end - offset
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(nanoseconds: 150_000_000)
                host.layoutSubtreeIfNeeded()
                try save("\(name)-scroll-\(index)", host: host)
            }
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func save<V: View>(_ name: String, host: NSHostingView<V>) throws {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CLIError("snapshot bitmap unavailable: \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = output.appendingPathComponent("\(name).png")
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CLIError("snapshot PNG unavailable: \(name)")
        }
        try png.write(to: url)
        print(url.path)
    }
}

/// Throwaway rules, remotes and keys backed by a temp directory and a fake `tailcat`.
@MainActor
private final class SampleWorld {
    nonisolated static let macMiniAddress = "tcMINI" + String(repeating: "q7Xk2PzR", count: 11)
    nonisolated static let officeAddress = "tcOFFICE" + String(repeating: "Lm4Vw9sT", count: 11)
    nonisolated static let laptopAddress = "tcLAPTOP" + String(repeating: "Hc8Nf3Yd", count: 11)
    nonisolated static let serveAddress = "tcSERVE" + String(repeating: "Bz5Jr1Ua", count: 11)

    let directory: URL
    let defaultsSuite = "tailcat.snapshot.\(UUID().uuidString)"
    let manager: RuleManager
    let settings: AppSettings
    let navigation = Navigation()

    let macMiniID = UUID(), officeID = UUID(), laptopID = UUID()
    let forwardID = UUID(), stoppedForwardID = UUID(), failingID = UUID()
    let socksID = UUID(), serveID = UUID(), recvID = UUID()

    /// `tailcatInstalled: false` is the first-run state: no binary anywhere, no data.
    init(tailcatInstalled: Bool, supportsPerf: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TailCat-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var path: String?
        if tailcatInstalled {
            let tailcat = directory.appendingPathComponent("tailcat")
            let script = supportsPerf ? Self.fakeTailcat.replacingOccurrences(of: "echo v0.7.0", with: "echo v0.8.0") : Self.fakeTailcat
            try Data(script.utf8).write(to: tailcat)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tailcat.path)
            path = tailcat.path
        }
        let found = path
        let locator = BinaryLocator(customPath: { found }, searchDirectories: [], environmentPATH: nil)
        settings = AppSettings(defaults: UserDefaults(suiteName: defaultsSuite)!)
        settings.language = L10n.language
        manager = RuleManager(store: RuleStore(directory: directory.appendingPathComponent("data")),
                              locator: locator, settings: settings,
                              makeConfig: { remotes in Self.config(remotes) })
    }

    func populate() async throws {
        manager.bootstrap()
        manager.saveRemote(Remote(id: macMiniID, name: "Mac mini", address: Self.macMiniAddress, sshUser: "me"))
        manager.saveRemote(Remote(id: officeID, name: "办公室 NAS", address: Self.officeAddress))
        manager.saveRemote(Remote(id: laptopID, name: "旧笔记本", address: Self.laptopAddress))
        manager.saveContact(Contact(name: "Alice 的 MacBook", publicKey: "nodekey:" + String(repeating: "3f9a", count: 16)))
        manager.recordKey(KeyMeta(name: "home", role: .server, address: "tcHOME" + String(repeating: "Wp6Ge2Kc", count: 11),
                                  region: "sfo"))

        manager.add(TunnelRule(id: forwardID, name: "Mac mini SSH", remoteID: macMiniID, mappings: ["2222:22"]))
        manager.add(TunnelRule(id: stoppedForwardID, name: "NAS 管理页", remoteID: officeID,
                               mappings: ["8080:80", "0:443", "3306:192.168.1.10:3306"]))
        manager.add(TunnelRule(id: failingID, name: "旧笔记本 屏幕共享", remoteID: laptopID, mappings: ["5900:5900"]))
        manager.add(TunnelRule(id: socksID, name: "出口代理", kind: .socks, remoteID: macMiniID))
        manager.add(TunnelRule(id: serveID, name: "本机 SSH 与网页", kind: .serve, key: "default",
                               services: ["ssh", "8000"], allow: manager.contacts.map(\.publicKey).joined(separator: ",")))
        manager.add(TunnelRule(id: recvID, name: "收件箱 · Downloads", kind: .recv,
                               recvDir: directory.appendingPathComponent("inbox").path))
        for id in [forwardID, failingID, socksID, serveID] { manager.runner(id: id)?.start() }

        try await waitUntil {
            self.manager.versionText != nil && !self.manager.savedKeys.isEmpty
                && [self.forwardID, self.socksID, self.serveID].allSatisfy { self.manager.runner(id: $0)?.state == .running }
                && self.manager.runner(id: self.serveID)?.serverAddress != nil
                && self.manager.runner(id: self.failingID)?.state.needsAttention == true
        }
        await manager.runner(id: forwardID)?.runPing()
        await manager.runner(id: socksID)?.runPing()
        await manager.pingRemote(id: officeID)
        await manager.pingRemote(id: laptopID)
    }

    func tearDown() {
        manager.shutdown()
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
    }

    func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw CLIError("sample data did not settle in \(Int(timeout))s") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Runners print what real tailcat would and then idle (the laptop one fails like an
    /// unreachable server); pings answer by address.
    private nonisolated static func config(_ remotes: RemoteDirectory) -> RunnerConfig {
        RunnerConfig(
            launch: { rule in
                let identity = remotes.remote(id: rule.remoteID)?.identity
                let script = identity?.address == laptopAddress
                    ? "echo 'tailcat: server did not answer: context deadline exceeded' >&2; exit 1"
                    : script(for: rule)
                return LaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], identity: identity)
            },
            probe: { spec, _, _ in ping(spec.identity?.address ?? "") })
    }

    private nonisolated static func ping(_ address: String) -> PingResult? {
        switch address {
        case macMiniAddress: return PingResult(latency: 0.0032, path: .direct(endpoint: "192.168.1.20:41641"))
        case officeAddress: return PingResult(latency: 0.0421, path: .derp(region: "1"))
        default: return nil
        }
    }

    private nonisolated static func script(for rule: TunnelRule) -> String {
        var lines: [String] = []
        switch rule.kind {
        case .forward:
            for (i, raw) in rule.cleanedMappings.enumerated() {
                guard let m = MappingSpec.parse(raw) else { continue }
                let target = "\(m.remoteHost ?? "localhost"):\(m.remotePort)"
                lines.append("# forwarding 127.0.0.1:\(m.localPort == 0 ? 49_152 + i : m.localPort) -> remote \(target)")
            }
        case .socks:
            lines.append("2026/09/30 10:00:00 SOCKS running at socks5h://127.0.0.1:1080")
        case .serve, .recv:
            lines.append(#"# 🐈 Server listening with saved key "default": \#(serveAddress)"#)
        }
        let echoes = lines.map { "echo '\($0)' >&2" }.joined(separator: "; ")
        return "\(echoes); exec sleep 120"
    }

    private static let fakeTailcat = """
    #!/bin/sh
    case "$*" in
      version) echo v0.7.0 ;;
      "genkey --list") printf 'default\\nhome\\n' ;;
      "parse "*) echo '{"ServerPublic":"nodekey:8c1e5a0f2b7d","RegionID":1}' ;;
      *ping*\(macMiniAddress)*) echo 'pong in 3.2ms via 192.168.1.20:41641' ;;
      *ping*\(officeAddress)*) echo 'pong in 42.1ms via DERP(1)' ;;
      *ping*) exit 1 ;;
      "ls -l "*) printf '%s\\n' 'drwxr-xr-x           96 Sep 30 09:12 Documents/' '-rw-r--r--      1048576 Sep 29 22:40 notes.txt' ;;
      *) echo "not simulated: $*" >&2; exit 2 ;;
    esac
    """
}
#endif
