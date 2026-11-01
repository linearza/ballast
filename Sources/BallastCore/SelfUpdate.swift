import Foundation

/// The pure decisions behind "Update to x.y.z": which asset to fetch, where it may come from,
/// and whether what came out of the zip is really the newer Ballast. The I/O lives in the app.
public enum SelfUpdate {
    public static let bundleID = "za.co.linear.ballast"
    public static let appName = "Ballast.app"

    /// What a GitHub `releases/latest` response says about a release.
    public struct ReleaseInfo: Equatable, Sendable {
        public var version: String
        public var page: URL
        /// The `Ballast-<version>.zip` asset, when the release has one we'd trust.
        public var download: URL?

        public init(version: String, page: URL, download: URL?) {
            self.version = version
            self.page = page
            self.download = download
        }
    }

    /// Parses a `releases/latest` body. Nil without a tag or a github.com release page.
    public static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(releaseLink) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { a -> (name: String, url: String)? in
            guard let n = a["name"] as? String, let u = a["browser_download_url"] as? String else { return nil }
            return (n, u)
        }
        return ReleaseInfo(version: version, page: page, download: pickAsset(assets, version: version))
    }

    /// The asset named exactly `Ballast-<version>.zip`, if its URL is one we'd download from.
    public static func pickAsset(_ assets: [(name: String, url: String)], version: String) -> URL? {
        guard let match = assets.first(where: { $0.name == "Ballast-\(version).zip" }),
              let url = URL(string: match.url), isAllowedDownload(url) else { return nil }
        return url
    }

    /// GitHub serves release assets from github.com and redirects to release-assets.githubusercontent.com
    /// (older releases redirected to objects.githubusercontent.com). Anything else is refused.
    public static let allowedHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    public static func isAllowedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    public enum Problem: Error, Equatable, Sendable {
        case wrongBundleID(String?)
        case versionMismatch(found: String?, offered: String)
        case notNewer(offered: String, running: String)
        case noExecutable
        case badSignature

        public var message: String {
            switch self {
            case .wrongBundleID: "The download isn't Ballast, so it was not installed."
            case .versionMismatch(let found, let offered): "The download is version \(found ?? "unknown"), not \(offered), so it was not installed."
            case .notNewer(let offered, let running): "Version \(offered) isn't newer than the \(running) you're running, so nothing was changed."
            case .noExecutable: "The download is damaged (no program inside), so it was not installed."
            case .badSignature: "The download's signature didn't check out, so it was not installed."
            }
        }
    }

    /// Nil when the extracted bundle is the offered version, newer than the one running, and intact.
    public static func validate(bundleID: String?, version: String?, offered: String, running: String,
                                executableExists: Bool, signatureValid: Bool) -> Problem? {
        guard bundleID == Self.bundleID else { return .wrongBundleID(bundleID) }
        guard version == offered else { return .versionMismatch(found: version, offered: offered) }
        guard compareVersions(offered, running) == .orderedDescending else { return .notNewer(offered: offered, running: running) }
        guard executableExists else { return .noExecutable }
        guard signatureValid else { return .badSignature }
        return nil
    }
}

/// One line in `actions.log`: time, outcome, title, detail, tab-separated.
public enum ActionLog {
    public static func append(to url: URL, date: Date, outcome: String, title: String, detail: String) {
        let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " | ") }
        let line = [ISO8601DateFormatter().string(from: date), outcome, clean(title), clean(detail)].joined(separator: "\t") + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
