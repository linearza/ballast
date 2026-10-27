import AppKit

/// Big folders in ~/Library/Caches, named after the app that owns them.
public struct AppCachesProvider: Provider {
    public init(minBytes: Int64 = 100_000_000) { self.minBytes = minBytes }
    public let id = "appCaches"
    public let title = "App caches"
    public let section = Section.caches
    public let symbol = "archivebox"
    let minBytes: Int64

    static let known: [String: String] = [
        "ms-playwright": "Playwright browsers",
        "Cypress": "Cypress binaries",
        "com.spotify.client": "Spotify",
        "typescript": "TypeScript",
    ]

    public func isPresent(_ env: Environment) async -> Bool { exists(env.path("Library/Caches")) }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        let dir = env.path("Library/Caches")
        let names = subfolders(dir).filter { !$0.hasPrefix("com.apple.") && !$0.hasPrefix(".") && !PackageCachesProvider.claimedCacheNames.contains($0) }
        var items: [Item] = []
        for name in names.sorted() {
            let url = dir.appending(path: name)
            let m = await measure([url])
            guard m.bytes >= minBytes else { continue }
            let bundleID = name.hasSuffix(".ShipIt") ? String(name.dropLast(".ShipIt".count)) : name
            var badges = Set<Badge>()
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { badges.insert(.running) }
            items.append(Item(id: "appCache.\(name)", title: Self.displayName(name), detail: "~/Library/Caches/\(name)",
                              paths: [url], bytes: m.bytes, sizeIsPartial: m.partial, risk: .regenerable, badges: badges))
        }
        return items
    }

    static func displayName(_ folder: String) -> String {
        if let k = known[folder] { return k }
        if folder.hasSuffix(".ShipIt") { return "\(displayName(String(folder.dropLast(".ShipIt".count)))) update leftovers" }
        if folder.contains("."), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folder) {
            return app.deletingPathExtension().lastPathComponent
        }
        return folder
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        planEach(ids, items: items, noun: "app") { item in
            [Step("Move \(item.title) cache to the Trash", .trash(item.paths), bytes: item.bytes, itemID: item.id)]
        }
    }
}
