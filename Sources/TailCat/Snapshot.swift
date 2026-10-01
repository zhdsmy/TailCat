#if DEBUG
import AppKit
import SwiftUI
import TailCatCore

/// `TailCat --snapshot <dir> [--dark]` (debug builds only): renders the main screens with sample
/// data into PNGs and exits, so UI changes can be reviewed without the real app, its data
/// (everything lives in a temp directory, tailcat is a fake script), or screen-recording access.
/// Window chrome, toolbars and the menu bar itself are not part of the images.
@MainActor
enum Snapshot {
    static func run(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: TailCat --snapshot <dir> [--dark]\n".utf8))
            exit(64)
        }
        let output = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
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

        let empty = try SampleWorld(tailcatInstalled: false)
        defer { empty.tearDown() }
        empty.manager.bootstrap()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await renderer.page("empty-menu", MenuContent(), in: empty)
        try await renderer.page("empty-manage", ManageView(), in: empty, size: CGSize(width: 900, height: 520))
        try await renderer.page("empty-settings", SettingsView(), in: empty)
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
        try await manage("contacts", .contacts, height: 500)
        try await page("settings", SettingsView())
        if let rule = manager.runner(id: sample.forwardID)?.rule {
            try await page("editor-forward", RuleEditor(rule: rule, isNew: false, contacts: manager.contacts) { _ in })
        }
        if let rule = manager.runner(id: sample.serveID)?.rule {
            try await page("editor-serve", RuleEditor(rule: rule, isNew: false, contacts: manager.contacts) { _ in })
        }
        if let remote = manager.remote(id: sample.macMiniID) {
            try await page("editor-remote", RemoteEditor(remote: remote, isNew: false) { _ in })
        }
        try await page("editor-new-socks", RuleEditor(rule: TunnelRule(kind: .socks), isNew: true, contacts: manager.contacts) { _ in })
        try await page("editor-new-recv", RuleEditor(rule: TunnelRule(kind: .recv), isNew: true, contacts: manager.contacts) { _ in })
        try await page("key-new-server", KeyCreateSheet(role: .server))
        try await page("key-new-client", KeyCreateSheet(role: .client))
        try await page("dns-wizard", DNSWizard())
        try await page("dns-wizard-published", DNSWizard(address: "tcDNS" + String(repeating: "q7Xk2PzR", count: 10)))
        try await page("contact-editor", ContactEditor(contact: Contact(), isNew: true) { _ in })
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
        let root = view
            .environmentObject(sample.manager)
            .environmentObject(sample.navigation)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let frame = CGRect(origin: .zero, size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        // Let `.task` / `.onAppear` work (auto-ping, key refresh) land before drawing.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = output.appendingPathComponent("\(name).png")
        try rep.representation(using: .png, properties: [:])?.write(to: url)
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
    let navigation = Navigation()

    let macMiniID = UUID(), officeID = UUID(), laptopID = UUID()
    let forwardID = UUID(), stoppedForwardID = UUID(), failingID = UUID()
    let socksID = UUID(), serveID = UUID(), recvID = UUID()

    /// `tailcatInstalled: false` is the first-run state: no binary anywhere, no data.
    init(tailcatInstalled: Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TailCat-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var path: String?
        if tailcatInstalled {
            let tailcat = directory.appendingPathComponent("tailcat")
            try Data(Self.fakeTailcat.utf8).write(to: tailcat)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tailcat.path)
            path = tailcat.path
        }
        let found = path
        let locator = BinaryLocator(customPath: { found }, searchDirectories: [], environmentPATH: nil)
        let settings = AppSettings(defaults: UserDefaults(suiteName: defaultsSuite)!)
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

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
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
