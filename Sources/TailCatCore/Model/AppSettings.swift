import Foundation

/// UserDefaults-backed preferences shared by the locator, runners and Settings UI.
public struct AppSettings: @unchecked Sendable {
    /// Bundle identifier (and so defaults domain) of releases before 0.1.0.
    public static let legacySuiteName = "app.tailcat.menubar"

    public enum Key {
        public static let customBinaryPath = "customBinaryPath"
        public static let derpmapURL = "derpmapURL"
        public static let verbose = "verbose"
        public static let notificationsEnabled = "notificationsEnabled"
        public static let statusLoopEnabled = "statusLoopEnabled"
        static let all = [customBinaryPath, derpmapURL, verbose, notificationsEnabled, statusLoopEnabled]
        static let migratedLegacyDefaults = "migratedLegacyDefaults"
    }

    /// Copies preferences saved under the old bundle identifier, once. Values already set in
    /// `new` win, so a user who changed a setting after upgrading never gets it reverted.
    public static func migrateLegacyDefaults(from old: UserDefaults, to new: UserDefaults) {
        guard !new.bool(forKey: Key.migratedLegacyDefaults) else { return }
        for key in Key.all where new.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { new.set(value, forKey: key) }
        }
        new.set(true, forKey: Key.migratedLegacyDefaults)
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var customBinaryPath: String? {
        get {
            let v = defaults.string(forKey: Key.customBinaryPath) ?? ""
            return v.isEmpty ? nil : v
        }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.customBinaryPath)
            } else {
                defaults.removeObject(forKey: Key.customBinaryPath)
            }
        }
    }

    public var derpmapURL: String {
        get { defaults.string(forKey: Key.derpmapURL) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.derpmapURL) }
    }

    public var verbose: Bool {
        get { defaults.bool(forKey: Key.verbose) }
        nonmutating set { defaults.set(newValue, forKey: Key.verbose) }
    }

    /// Defaults to on; first launch has no key, so treat missing as true.
    public var notificationsEnabled: Bool {
        get {
            if defaults.object(forKey: Key.notificationsEnabled) == nil { return true }
            return defaults.bool(forKey: Key.notificationsEnabled)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    public var statusLoopEnabled: Bool {
        get { defaults.bool(forKey: Key.statusLoopEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.statusLoopEnabled) }
    }

    /// Global flags that must precede the subcommand (`--key`, `--verbose`, `--derpmap-url`).
    public func globalFlagArguments(key: String = "") -> [String] {
        var args: [String] = []
        if !key.isEmpty { args.append("--key=\(key)") }
        if verbose { args.append("--verbose") }
        let url = derpmapURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty { args.append("--derpmap-url=\(url)") }
        return args
    }
}
