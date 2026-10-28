import Foundation

/// Package manager download caches. Cleared with the tool's own command when it's installed.
public struct PackageCachesProvider: Provider {
    public init() {}
    public let id = "packageCaches"
    public let title = "Package caches"
    public let section = Section.caches
    public let symbol = "shippingbox.circle"

    /// Each cache can live in several places; the item holds the ones that exist.
    static let caches: [(key: String, title: String, rels: [String], argv: [String]?)] = [
        ("npm", "npm", [".npm/_cacache"], ["npm", "cache", "clean", "--force"]),
        ("pnpm", "pnpm", ["Library/pnpm/store"], ["pnpm", "store", "prune"]),
        ("yarn", "Yarn (classic)", ["Library/Caches/Yarn"], ["yarn", "cache", "clean"]),
        ("yarnBerry", "Yarn Berry", [".yarn/berry/cache"], nil),
        ("bun", "Bun", [".bun/install/cache"], ["bun", "pm", "cache", "rm"]),
        ("deno", "Deno", ["Library/Caches/deno"], nil),
        ("pip", "pip", ["Library/Caches/pip"], ["pip3", "cache", "purge"]),
        ("uv", "uv", [".cache/uv"], ["uv", "cache", "clean"]),
        ("poetry", "Poetry", ["Library/Caches/pypoetry/cache", "Library/Caches/pypoetry/artifacts"], nil),
        ("conda", "conda package", ["miniforge3/pkgs", "miniconda3/pkgs", "anaconda3/pkgs", "mambaforge/pkgs", ".conda/pkgs"],
         ["conda", "clean", "--all", "-y"]),
        ("cargo", "Cargo", [".cargo/registry"], nil),
        ("go", "Go build", ["Library/Caches/go-build"], ["go", "clean", "-cache"]),
        ("gomod", "Go module", ["go/pkg/mod"], ["go", "clean", "-modcache"]),
        ("cocoapods", "CocoaPods", ["Library/Caches/CocoaPods"], ["pod", "cache", "clean", "--all"]),
        ("swiftpm", "Swift Package Manager", ["Library/Caches/org.swift.swiftpm"], nil),
        ("carthage", "Carthage", ["Library/Caches/org.carthage.CarthageKit"], nil),
        ("gradle", "Gradle", [".gradle/caches"], nil),
        ("maven", "Maven", [".m2/repository"], nil),
        ("ivy", "Ivy", [".ivy2/cache"], nil),
        ("sbt", "sbt", [".sbt/boot"], nil),
        ("coursier", "Coursier", ["Library/Caches/Coursier"], nil),
        ("nuget", "NuGet", [".nuget/packages"], ["dotnet", "nuget", "locals", "all", "--clear"]),
        ("composer", "Composer", ["Library/Caches/composer", ".composer/cache"], ["composer", "clear-cache"]),
        ("bundler", "Bundler", [".bundle/cache"], nil),
        ("electron", "Electron download", ["Library/Caches/electron"], nil),
    ]

    /// Folders in ~/Library/Caches that belong to this provider, so AppCaches leaves them out.
    static let claimedCacheNames: Set<String> = Set(caches.flatMap(\.rels).compactMap {
        $0.hasPrefix("Library/Caches/") ? $0.dropFirst("Library/Caches/".count).split(separator: "/").first.map(String.init) : nil
    })

    public func isPresent(_ env: Environment) async -> Bool {
        Self.caches.contains { $0.rels.contains { exists(env.path($0)) } }
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        await measured(Self.caches.compactMap { c in
            let found = c.rels.filter { exists(env.path($0)) }
            guard !found.isEmpty else { return nil }
            return Item(id: "cache.\(c.key)", title: "\(c.title) cache", detail: found.map { "~/\($0)" }.joined(separator: ", "),
                        paths: found.map { env.path($0) }, bytes: 0, risk: .regenerable)
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
