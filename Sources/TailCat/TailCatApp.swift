import AppKit
import Combine
import SwiftUI
import TailCatCore
@preconcurrency import UserNotifications

@main
enum Entry {
    @MainActor static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--snapshot") { Snapshot.run(arguments: CommandLine.arguments) }
        #endif
        // Before `TailCatApp.main()`: the delegate's `RuleManager` reads settings as it is created.
        if let id = Bundle.main.bundleIdentifier, id != AppSettings.legacySuiteName,
           let legacy = UserDefaults(suiteName: AppSettings.legacySuiteName) {
            AppSettings.migrateLegacyDefaults(from: legacy, to: .standard)
        }
        TailCatApp.main()
    }
}

struct TailCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("TailCat", systemImage: menuIcon) {
            MenuContent()
                .environmentObject(delegate.manager)
                .environmentObject(delegate.navigation)
        }
        .menuBarExtraStyle(.window)

        Window("TailCat", id: "manage") {
            ManageView()
                .environmentObject(delegate.manager)
                .environmentObject(delegate.navigation)
        }
        .defaultSize(width: 900, height: 620)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environmentObject(delegate.manager)
        }
    }

    private var menuIcon: String {
        delegate.manager.runners.contains { $0.state == .running } ? "cat.fill" : "cat"
    }
}

/// What the management window shows; shared so menu actions can jump to an item.
@MainActor
final class Navigation: ObservableObject {
    @Published var selection: SidebarItem?
    /// Set by the menu to open the editor for a new rule once the window is up.
    @Published var pendingNewKind: TunnelKind?
}

/// Owns the one `RuleManager` the scenes display.
///
/// `App.init` runs before SwiftUI installs `@StateObject` storage. Capturing `self` there and
/// calling `bootstrap()` later starts a different manager from the one the windows observe, so the
/// UI stays on an empty, never-located instance.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    let manager = RuleManager()
    let navigation = Navigation()
    private var runnerObserver: AnyCancellable?

    override init() {
        super.init()
        runnerObserver = manager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            UNUserNotificationCenter.current().delegate = self
            manager.onNotify = { title, body in AppNotifications.post(title: title, body: body) }
            manager.onFilesReceived = { rule, urls in
                let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: "、")
                let more = urls.count > 3 ? " 等 \(urls.count) 项" : ""
                AppNotifications.post(title: rule.name, body: "收到 \(names)\(more)", reveal: urls.first)
            }
            AppNotifications.requestAuthorizationIfNeeded()
            manager.bootstrap()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { manager.shutdown() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo[AppNotifications.revealKey] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }

    /// A menu bar app counts as frontmost while its window is open; show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
