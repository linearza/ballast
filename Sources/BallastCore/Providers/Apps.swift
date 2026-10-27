import AppKit
import CoreServices

/// Installed apps, with when you last opened them, and uninstalling with their leftovers.
public struct AppsProvider: Provider {
    public init() {}
    public let id = "apps"
    public let title = "Apps"
    public let section = Section.apps
    public let symbol = "app"

    /// Apps another provider already covers, so they aren't counted twice.
    static let coveredElsewhere: Set<String> = ["com.apple.dt.Xcode", "com.docker.docker", "com.electron.ollama"]

    static let leftoverDirs = ["Application Support", "Caches", "Containers", "Group Containers", "Preferences",
                               "Saved Application State", "HTTPStorages", "WebKit", "LaunchAgents"]

    func bundleID(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    public func isPresent(_ env: Environment) async -> Bool { true }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        for dir in env.applications {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
            for name in names {
                let url = dir.appending(path: name)
                let bid = bundleID(url)
                if let bid, Self.coveredElsewhere.contains(bid) { continue }
                var badges = Set<Badge>()
                if let bid, !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { badges.insert(.running) }
                if let used = lastUsed(url) { badges.insert(.lastUsed(used)) }
                items.append(Item(id: "app.\(url.path)", title: url.deletingPathExtension().lastPathComponent,
                                  detail: bid, paths: [url], bytes: 0, risk: .review, badges: badges))
            }
        }
        return await measured(items)
    }

    func lastUsed(_ app: URL) -> Date? {
        guard let md = MDItemCreate(nil, app.path as CFString) else { return nil }
        return MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
    }

    /// Files in ~/Library named after the bundle id.
    func leftovers(_ bundleID: String, env: Environment) -> [URL] {
        Self.leftoverDirs.flatMap { rel -> [URL] in
            let dir = env.path("Library/\(rel)")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { $0.contains(bundleID) }.sorted().map { dir.appending(path: $0) }
        }
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = Plan()
        for id in ids {
            guard let item = items.first(where: { $0.id == id }), let app = item.paths.first else { continue }
            let bid = item.detail
            if bid?.hasPrefix("com.apple.") == true {
                plan.refusals.append(Refusal(itemID: id, reason: "Part of macOS"))
                continue
            }
            if let w = inUseWarning(item, noun: "app") { plan.warnings.append(w) }
            plan.steps.append(Step("Move \(item.title) to the Trash", .trash([app]), bytes: item.bytes, itemID: id))
            guard let bid else { continue }
            let found = leftovers(bid, env: env)
            if !found.isEmpty {
                // Containers aren't measured: reading them can bring up a permission prompt.
                let readable = found.filter { !$0.path.contains("/Containers/") }
                let bytes = await measure(readable).bytes
                plan.steps.append(Step("Move \(item.title)'s settings and caches to the Trash", .trash(found), bytes: bytes, itemID: id))
            }
        }
        return plan
    }
}
