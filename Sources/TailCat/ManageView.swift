import AppKit
import SwiftUI
import TailCatCore
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case rule(UUID)
    case remote(UUID)
    case keys
    case contacts
}

private struct RuleDraft: Identifiable {
    var rule: TunnelRule
    var isNew: Bool
    var importError: String? = nil
    var id: UUID { rule.id }
}

private struct RemoteDraft: Identifiable {
    var remote: Remote
    var isNew: Bool
    var id: UUID { remote.id }
}

struct ManageView: View {
    @EnvironmentObject var manager: RuleManager
    @EnvironmentObject var navigation: Navigation
    @ViewState private var ruleDraft: RuleDraft?
    @ViewState private var remoteDraft: RemoteDraft?
    @ViewState private var showWizard = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = manager.loadError {
                HStack(alignment: .top) {
                    Text(Diagnostics.mask(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button { manager.dismissError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭错误提示")
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            NavigationSplitView {
                List(selection: $navigation.selection) {
                    ForEach(TunnelKind.displayOrder, id: \.self) { kind in
                        let runners = manager.runners.filter { $0.rule.kind == kind }
                        if !runners.isEmpty {
                            Section(kind.label) {
                                ForEach(runners) { runner in
                                    SidebarRow(runner: runner).tag(SidebarItem.rule(runner.id))
                                }
                            }
                        }
                    }
                    Section("远端") {
                        ForEach(manager.remotes) { remote in
                            HStack {
                                Label(remote.name, systemImage: "desktopcomputer")
                                Spacer()
                                RemoteStatusDot(status: manager.remotePings[remote.id])
                            }
                            .tag(SidebarItem.remote(remote.id))
                            .help("拖入文件即可发送到该远端")
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                loadURLs(providers) { FileSender.send($0, to: remote, using: manager.cli) }
                                return true
                            }
                        }
                    }
                    Section("工具") {
                        Label("密钥", systemImage: "key").tag(SidebarItem.keys)
                        Label("通讯录", systemImage: "person.2").tag(SidebarItem.contacts)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
                .background(SplitSeamAlign())
                .toolbar {
                    ToolbarItem {
                        Menu {
                            Button("转发（本机端口 → 远端）") { newRule(.forward) }
                            Button("SOCKS 代理") { newRule(.socks) }
                            Divider()
                            Button("服务（把本机端口/目录/SSH 提供给别人）") { newRule(.serve) }
                            Button("收件箱（接收文件）") { newRule(.recv) }
                            Divider()
                            Button("远端…") { remoteDraft = RemoteDraft(remote: Remote(), isNew: true) }
                            Button("DNS 发布向导…") { showWizard = true }
                        } label: { Label("新增", systemImage: "plus") }
                    }
                }
            } detail: {
                detail
            }
        }
        .sheet(item: $ruleDraft) { draft in
            RuleEditor(rule: draft.rule, isNew: draft.isNew, contacts: manager.contacts,
                       importError: draft.importError) { saved in
                if draft.isNew {
                    guard manager.add(saved) else { return false }
                    navigation.selection = .rule(saved.id)
                    return true
                } else {
                    return manager.update(saved)
                }
            }
        }
        .sheet(item: $remoteDraft) { draft in
            RemoteEditor(remote: draft.remote, isNew: draft.isNew) { saved in
                guard manager.saveRemote(saved) else { return false }
                navigation.selection = .remote(saved.id)
                return true
            }
        }
        .sheet(isPresented: $showWizard) { DNSWizard() }
        .onChange(of: navigation.pendingNewKind) { kind in
            guard let kind else { return }
            navigation.pendingNewKind = nil
            newRule(kind)
        }
        .onAppear {
            if let kind = navigation.pendingNewKind {
                navigation.pendingNewKind = nil
                newRule(kind)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection {
        case .rule(let id):
            if let runner = manager.runner(id: id) {
                RuleDetail(runner: runner,
                           onEdit: { ruleDraft = RuleDraft(rule: runner.rule, isNew: false) },
                           onDelete: { if manager.remove(id: id) { navigation.selection = nil } },
                           onShowRemote: { navigation.selection = .remote($0) },
                           onDuplicate: { ruleDraft = RuleDraft(rule: runner.rule.duplicate(), isNew: true) })
                    .id(id)
            } else {
                placeholder
            }
        case .remote(let id):
            if let remote = manager.remote(id: id) {
                RemoteDetail(remote: remote,
                             onEdit: { remoteDraft = RemoteDraft(remote: remote, isNew: false) },
                             onDeleted: { navigation.selection = nil },
                             onNewRule: { newRule($0, remoteID: id) },
                             onShowRule: { navigation.selection = .rule($0) },
                             onBrowse: { openWebsite(remoteID: id) })
                    .id(id)
            } else {
                placeholder
            }
        case .keys:
            KeysView()
        case .contacts:
            ContactsView()
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            if manager.binaryPath == nil { MissingTailcat() }
            if manager.runners.isEmpty && manager.remotes.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有任何规则").font(.title3)
                    Text("转发：把远端机器的端口映射到本机；服务：把本机的端口、目录或 SSH 提供给别人。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button("新建转发…") { newRule(.forward) }
                        Button("新建服务…") { newRule(.serve) }
                        Button("添加远端…") { remoteDraft = RemoteDraft(remote: Remote(), isNew: true) }
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("选择左侧项目，或点 + 新增转发、服务、收件箱或远端").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 480)
        .padding()
    }

    private func newRule(_ kind: TunnelKind, remoteID: UUID? = nil) {
        var draft = TunnelRule(kind: kind)
        var importError: String?
        switch kind {
        case .forward:
            draft.remoteID = remoteID ?? manager.remotes.first?.id
            // A copied address or `tailcat forward …` command pre-fills the form.
            if remoteID == nil, let clip = Clipboard.string {
                switch AddressTools.parseForward(clip) {
                case .success(let imported):
                    imported.apply(to: &draft, remotes: manager.remotes)
                    draft.name = "未命名"
                case .failure(let error):
                    // Ordinary clipboard text is not an import attempt.
                    if clip.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("tailcat ") {
                        importError = error.localizedDescription
                    }
                }
            }
        case .socks:
            draft.remoteID = remoteID
            draft.name = "SOCKS"
        case .serve:
            draft.name = "本机服务"
            draft.autoRestart = true
        case .recv:
            draft.name = "收件箱"
        }
        ruleDraft = RuleDraft(rule: draft, isNew: true, importError: importError)
    }

    private func openWebsite(remoteID: UUID) {
        guard let runner = manager.websiteRule(for: remoteID) else { return }
        if runner.state.isActive {
            if let listener = runner.listeners.first, let url = URL(string: "http://\(listener.hostPort)/") {
                NSWorkspace.shared.open(url)
            }
        } else {
            runner.start()
        }
        navigation.selection = .rule(runner.id)
    }
}

private struct SidebarRow: View {
    @ObservedObject var runner: TunnelRunner
    var body: some View {
        HStack {
            StatusDot(state: runner.state)
            Text(runner.rule.name)
            Spacer()
            if runner.rule.needsAllowWarning {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.red).help("未设置允许列表")
            }
            if let ping = runner.lastPing {
                Text(ping.isDirect ? "直连" : "中继")
                    .font(.caption2)
                    .foregroundStyle(ping.isDirect ? .green : .orange)
            }
        }
    }
}

/// Hides the 1pt split divider line and lines the detail title-bar background up with it.
///
/// AppKit starts the detail column's title-bar background (`NSTitlebarBackgroundView`) at the
/// divider's 4pt hit area, left of where the detail column starts, so the sidebar edge jogs at the title bar.
/// Both views are private and AppKit re-lays them out on every resize, so we correct the background
/// whenever its frame changes and keep its right edge on the title bar's right edge.
private struct SplitSeamAlign: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = SeamAlignView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SeamAlignView: NSView {
    private var observers: [NSObjectProtocol] = []
    private weak var line: NSView?
    private weak var background: NSView?
    private var backgroundObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let realign: (Notification) -> Void = { [weak self] _ in self?.align() }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main, using: realign))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main, using: realign))
        scheduleAlign()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    override func layout() {
        super.layout()
        scheduleAlign()
    }

    /// The title bar is laid out after the split view on first show, so also try on the next turn.
    private func scheduleAlign() {
        align()
        DispatchQueue.main.async { [weak self] in self?.align() }
    }

    private func align() {
        guard let window else { return }
        var root: NSView? = window.contentView
        while let parent = root?.superview { root = parent }
        guard let root,
              let divider = find(in: root, where: { $0.className == "NSVibrantSplitDividerView" }),
              let line = divider.subviews.first(where: { $0 is NSVisualEffectView }) else { return }
        self.line = line
        if line.alphaValue != 0 { line.alphaValue = 0 }

        if background?.window !== window {
            let lineX = line.convert(line.bounds, to: nil).minX
            let backgrounds = findAll(in: root) { $0.className == "NSTitlebarBackgroundView" && !$0.isHidden }
            // The detail column's background is the visible one that starts near the divider.
            guard let found = backgrounds.first(where: {
                abs($0.convert($0.bounds, to: nil).minX - lineX) < 8
            }) else { return }
            watch(found)
        }
        fitBackground()
    }

    private func watch(_ view: NSView) {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        background = view
        view.postsFrameChangedNotifications = true
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitBackground() }
        }
    }

    /// Runs synchronously from the frame-change notification so live resize never shows AppKit's frame.
    private func fitBackground() {
        guard let line, let background, let superview = background.superview else { return }
        // With the line hidden, its column shows the sidebar-coloured window background, so the
        // detail column visibly starts at the line's right edge.
        let edge = line.convert(line.bounds, to: superview).maxX
        let current = background.frame
        let target = NSRect(x: edge, y: current.minY,
                            width: superview.bounds.maxX - edge, height: current.height)
        guard abs(current.minX - target.minX) > 0.25 || abs(current.width - target.width) > 0.25 else { return }
        background.frame = target
    }

    private func find(in view: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(view) { return view }
        for subview in view.subviews {
            if let found = find(in: subview, where: match) { return found }
        }
        return nil
    }

    private func findAll(in view: NSView, where match: (NSView) -> Bool) -> [NSView] {
        (match(view) ? [view] : []) + view.subviews.flatMap { findAll(in: $0, where: match) }
    }
}
