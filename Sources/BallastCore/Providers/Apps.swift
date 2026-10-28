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

    /// Where apps keep what you made in them, not just settings and caches.
    static let dataDirs = ["Application Support", "Containers", "Group Containers"]

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
    /// Library entries named after `bundleID`, leaving out ones that belong to another installed app
    /// whose id is longer (com.google.Chrome.canary when removing com.google.Chrome).
    func leftovers(_ bundleID: String, otherIDs: [String], env: Environment) -> [URL] {
        let others = otherIDs.filter { $0 != bundleID && $0.count > bundleID.count }
        return Self.leftoverDirs.flatMap { rel -> [URL] in
            let dir = env.path("Library/\(rel)")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { name in
                Self.named(name, after: bundleID) && !others.contains { Self.named(name, after: $0) }
            }.sorted().map { dir.appending(path: $0) }
        }
    }

    /// `com.x.app`, `com.x.app.plist`, `com.x.app.helper` or `TEAMID.com.x.app`, but not `com.x.appBeta`.
    static func named(_ name: String, after bundleID: String) -> Bool {
        var stem = name
        for ext in [".plist", ".savedState", ".binarycookies"] where stem.hasSuffix(ext) {
            stem = String(stem.dropLast(ext.count))
        }
        return stem == bundleID || stem.hasPrefix(bundleID + ".") || stem.hasSuffix("." + bundleID)
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = Plan()
        for id in ids {
            guard let item = items.first(where: { $0.id == id }), let app = item.paths.first else { continue }
            let bid = item.detail
            // Apple's App Store apps (Pages, Numbers, Keynote) carry a receipt and can go; the rest ship with macOS.
            if bid?.hasPrefix("com.apple.") == true, !exists(app.appending(path: "Contents/_MASReceipt")) {
                plan.refusals.append(Refusal(itemID: id, reason: "Part of macOS"))
                continue
            }
            if let w = inUseWarning(item, noun: "app") { plan.dangers.append(w) }
            plan.steps.append(Step("Move \(item.title) to the Trash", .trash([app]), bytes: item.bytes, itemID: id))
            guard let bid else { continue }
            let found = leftovers(bid, otherIDs: items.compactMap(\.detail), env: env)
            if !found.isEmpty {
                // Containers aren't measured: reading them can bring up a permission prompt.
                let readable = found.filter { !$0.path.contains("/Containers/") }
                let bytes = await measure(readable).bytes
                plan.steps.append(Step("Move \(item.title)'s settings, caches and data to the Trash", .trash(found), bytes: bytes, itemID: id))
                if found.contains(where: { url in Self.dataDirs.contains { url.path.contains("/Library/\($0)/") } }) {
                    plan.dangers.append("\(item.title)'s own data goes too, like documents or libraries kept inside the app. If you saved work in \(item.title), export it first.")
                }
            }
        }
        return plan
    }
}
