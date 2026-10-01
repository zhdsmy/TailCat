import Foundation

/// Compares the running app with the latest GitHub release. Runs only when the user asks: the app
/// makes no network requests of its own otherwise.
public enum UpdateCheck {
    public static let releasesPage = URL(string: "https://github.com/zhdsmy/TailCat/releases/latest")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/zhdsmy/TailCat/releases/latest")!

    /// The latest release's version if it is newer than `current`, nil if `current` is up to date.
    public static func newerRelease(than current: String) async throws -> TailcatVersion? {
        var request = URLRequest(url: latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try newer(than: current, releaseJSON: data)
    }

    static func newer(than current: String, releaseJSON: Data) throws -> TailcatVersion? {
        struct Release: Decodable { var tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: releaseJSON).tag_name
        guard let latest = TailcatVersion.parse(tag), let running = TailcatVersion.parse(current) else {
            throw URLError(.cannotParseResponse)
        }
        return latest > running ? latest : nil
    }
}
