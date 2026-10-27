import Foundation

/// Node versions from nvm, fnm, Volta, asdf and mise.
public struct NodeProvider: Provider {
    public init() {}
    public let id = "node"
    public let title = "Node"
    public let section = Section.toolchains
    public let symbol = "hexagon"

    static let fnmDirs = ["Library/Application Support/fnm/node-versions", ".local/share/fnm/node-versions"]

    public func isPresent(_ env: Environment) async -> Bool {
        ([".nvm/versions/node", ".volta/tools/image/node", ".asdf/installs/nodejs"] + Self.fnmDirs).contains { exists(env.path($0)) }
            || exists(miseInstalls(env, tool: "node"))
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        func add(_ manager: String, _ folder: URL, _ name: String, isDefault: Bool) {
            let version = normalizeVersion(name)
            var badges = Set<Badge>()
            if isDefault { badges.insert(.isDefault) }
            if let pin = pinBadge(pins, pins.node, installed: version) { badges.insert(pin) }
            items.append(Item(id: "node.\(manager).\(name)", title: "Node \(version)", detail: "\(manager) · with global packages",
                              paths: [folder.appending(path: name)], bytes: 0, risk: .regenerable, badges: badges))
        }

        let nvm = env.path(".nvm/versions/node")
        let nvmVersions = subfolders(nvm)
        let nvmDefault = resolveNvmAlias(env, installed: nvmVersions)
        for v in nvmVersions { add("nvm", nvm, v, isDefault: v == nvmDefault) }
        if exists(env.path(".nvm/.cache")) {
            items.append(Item(id: "node.nvm.cache", title: "nvm download cache", detail: "Downloaded Node archives",
                              paths: [env.path(".nvm/.cache")], bytes: 0, risk: .regenerable))
        }

        for dir in Self.fnmDirs {
            let root = env.path(dir)
            let def = (try? FileManager.default.destinationOfSymbolicLink(
                atPath: root.deletingLastPathComponent().appending(path: "aliases/default").path))
                .map { URL(filePath: $0).deletingLastPathComponent().lastPathComponent }
            for v in subfolders(root) { add("fnm", root, v, isDefault: v == def) }
        }

        let volta = env.path(".volta/tools/image/node")
        let voltaDefault = (try? Data(contentsOf: env.path(".volta/tools/user/platform.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["node"] as? [String: Any])?["runtime"] as? String }
        for v in subfolders(volta) { add("volta", volta, v, isDefault: v == voltaDefault) }

        let asdf = env.path(".asdf/installs/nodejs")
        let asdfDefault = asdfGlobal(env, tool: "nodejs")
        for v in subfolders(asdf) { add("asdf", asdf, v, isDefault: v == asdfDefault) }

        let mise = miseInstalls(env, tool: "node")
        let miseVersions = subfolders(mise)
        let miseDefault = miseGlobal(env, tools: ["node", "nodejs"], installed: miseVersions)
        for v in miseVersions { add("mise", mise, v, isDefault: v == miseDefault) }

        return await measured(items)
    }

    /// nvm's default alias names a version prefix (`24`), another alias (`lts/iron`), or `node`.
    func resolveNvmAlias(_ env: Environment, installed: [String]) -> String? {
        var alias = firstLine(env.path(".nvm/alias/default"))
        for _ in 0..<4 {
            guard let a = alias, exists(env.path(".nvm/alias/\(a)")) else { break }
            alias = firstLine(env.path(".nvm/alias/\(a)"))
        }
        guard let alias else { return nil }
        let newestFirst = installed.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        if alias == "node" || alias == "stable" { return newestFirst.first }
        return newestFirst.first { versionMatches(pin: alias, installed: $0) }
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        let source = "source \(shellQuote(env.path(".nvm/nvm.sh").path))"
        return planEach(ids, items: items, noun: "Node") { item in
            let parts = item.id.split(separator: ".", maxSplits: 2).map(String.init)
            let manager = parts[1], name = parts[2]
            let kind: StepKind
            switch manager {
            case "nvm" where name == "cache": kind = .shell("\(source) && nvm cache clear")
            case "nvm": kind = .shell("\(source) && nvm uninstall \(shellQuote(name))")
            case "fnm": kind = .command(argv: ["fnm", "uninstall", name])
            case "asdf": kind = .command(argv: ["asdf", "uninstall", "nodejs", name])
            case "mise": kind = .command(argv: ["mise", "uninstall", "node@\(name)"])
            default: kind = .trash(item.paths)
            }
            return [Step("Remove \(item.title)", kind, bytes: item.bytes, itemID: item.id)]
        }
    }
}
