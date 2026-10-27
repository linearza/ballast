import Foundation

/// Package manager download caches. Cleared with the tool's own command when it's installed.
public struct PackageCachesProvider: Provider {
    public init() {}
    public let id = "packageCaches"
    public let title = "Package caches"
    public let section = Section.caches
    public let symbol = "shippingbox.circle"

    static let caches: [(key: String, title: String, rel: String, argv: [String]?)] = [
        ("npm", "npm", ".npm/_cacache", ["npm", "cache", "clean", "--force"]),
        ("pnpm", "pnpm", "Library/pnpm/store", ["pnpm", "store", "prune"]),
        ("yarn", "Yarn (classic)", "Library/Caches/Yarn", ["yarn", "cache", "clean"]),
        ("yarnBerry", "Yarn Berry", ".yarn/berry/cache", nil),
        ("pip", "pip", "Library/Caches/pip", ["pip3", "cache", "purge"]),
        ("cargo", "Cargo", ".cargo/registry", nil),
        ("go", "Go", "Library/Caches/go-build", ["go", "clean", "-cache"]),
        ("cocoapods", "CocoaPods", "Library/Caches/CocoaPods", ["pod", "cache", "clean", "--all"]),
        ("gradle", "Gradle", ".gradle/caches", nil),
    ]

    /// Folders in ~/Library/Caches that belong to this provider, so AppCaches leaves them out.
    static let claimedCacheNames: Set<String> = Set(caches.compactMap {
        $0.rel.hasPrefix("Library/Caches/") ? String($0.rel.dropFirst("Library/Caches/".count)) : nil
    })

    public func isPresent(_ env: Environment) async -> Bool {
        Self.caches.contains { exists(env.path($0.rel)) }
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        await measured(Self.caches.filter { exists(env.path($0.rel)) }.map { c in
            Item(id: "cache.\(c.key)", title: "\(c.title) cache", detail: "~/\(c.rel)", paths: [env.path(c.rel)], bytes: 0, risk: .regenerable)
        })
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = Plan()
        for id in ids {
            guard let item = items.first(where: { $0.id == id }),
                  let c = Self.caches.first(where: { "cache.\($0.key)" == id }) else { continue }
            if let argv = c.argv, await env.runner.which(argv[0]) != nil {
                plan.steps.append(Step("Clear the \(item.title)", .command(argv: argv), bytes: item.bytes, itemID: id))
            } else {
                plan.steps.append(Step("Move the \(item.title) to the Trash", .trash(item.paths), bytes: item.bytes, itemID: id))
            }
        }
        return plan
    }
}
