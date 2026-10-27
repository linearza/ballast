import Foundation

/// Ruby versions from RVM, rbenv, asdf and mise, each with its gems.
public struct RubyProvider: Provider {
    public init() {}
    public let id = "ruby"
    public let title = "Ruby"
    public let section = Section.toolchains
    public let symbol = "diamond"

    static let implode = "ruby.rvm.implode"

    public func isPresent(_ env: Environment) async -> Bool {
        [".rvm/rubies", ".rbenv/versions", ".asdf/installs/ruby"].contains { exists(env.path($0)) }
            || exists(miseInstalls(env, tool: "ruby"))
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        let rvm = env.path(".rvm")

        // RVM: rubies/ruby-X plus gems/ruby-X and gems/ruby-X@gemset.
        let rvmDefault = (try? String(contentsOf: rvm.appending(path: "config/alias"), encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("default=") }
            .map { String($0.dropFirst("default=".count).split(separator: "@").first ?? "") }
        let gemDirs = subfolders(rvm.appending(path: "gems"))
        for name in subfolders(rvm.appending(path: "rubies")) {
            let version = name.hasPrefix("ruby-") ? String(name.dropFirst(5)) : name
            var paths = [rvm.appending(path: "rubies/\(name)")]
            paths += gemDirs.filter { $0 == name || $0.hasPrefix("\(name)@") }.map { rvm.appending(path: "gems/\($0)") }
            var badges = Set<Badge>()
            if rvmDefault == name { badges.insert(.isDefault) }
            if let pin = pinBadge(pins, pins.ruby, installed: version) { badges.insert(pin) }
            items.append(Item(id: "ruby.rvm.\(version)", title: name.hasPrefix("ruby-") ? "Ruby \(version)" : name,
                              detail: paths.count > 1 ? "rvm · with gems" : "rvm", paths: paths, bytes: 0,
                              risk: .regenerable, badges: badges))
        }
        let downloads = [rvm.appending(path: "src"), rvm.appending(path: "archives")].filter(exists)
        if !downloads.isEmpty {
            items.append(Item(id: "ruby.rvm.downloads", title: "RVM downloads and sources",
                              detail: "Kept after installing; not needed to run Ruby", paths: downloads, bytes: 0,
                              risk: .regenerable))
        }
        if exists(rvm.appending(path: "backup")) {
            items.append(Item(id: "ruby.rvm.backup", title: "RVM backups", detail: "Old gem sets RVM set aside",
                              paths: [rvm.appending(path: "backup")], bytes: 0, risk: .review))
        }

        // rbenv, asdf and mise keep one folder per version; gems live inside it.
        let mise = miseInstalls(env, tool: "ruby")
        let managers: [(key: String, dir: URL, def: String?)] = [
            ("rbenv", env.path(".rbenv/versions"), firstLine(env.path(".rbenv/version"))),
            ("asdf", env.path(".asdf/installs/ruby"), asdfGlobal(env, tool: "ruby")),
            ("mise", mise, miseGlobal(env, tools: ["ruby"], installed: subfolders(mise))),
        ]
        for m in managers {
            for version in subfolders(m.dir) {
                var badges = Set<Badge>()
                if m.def == version { badges.insert(.isDefault) }
                if let pin = pinBadge(pins, pins.ruby, installed: version) { badges.insert(pin) }
                items.append(Item(id: "ruby.\(m.key).\(version)", title: "Ruby \(version)", detail: "\(m.key) · with gems",
                                  paths: [m.dir.appending(path: version)], bytes: 0, risk: .regenerable, badges: badges))
            }
        }
        return await measured(items)
    }

    public func extraActions(_ items: [Item]) -> [ProviderAction] {
        let rvmItems = items.filter { $0.id.hasPrefix("ruby.rvm.") }
        guard !rvmItems.isEmpty else { return [] }
        return [ProviderAction(id: Self.implode, title: "Uninstall RVM completely", itemIDs: rvmItems.map(\.id))]
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        let source = "source \(shellQuote(env.path(".rvm/scripts/rvm").path))"
        if ids.contains(Self.implode) {
            let bytes = await measure([env.path(".rvm")]).bytes
            return Plan(steps: [Step("Remove RVM and everything it installed", .shell("\(source) && rvm implode --force"), bytes: bytes)],
                        warnings: ["This removes every Ruby version and gem installed with RVM.",
                                   "Afterwards, remove the RVM lines from ~/.zshrc, ~/.zprofile or ~/.bash_profile."])
        }
        return planEach(ids, items: items, noun: "Ruby") { item in
            let parts = item.id.split(separator: ".", maxSplits: 2).map(String.init)
            let manager = parts[1], version = parts.count > 2 ? parts[2] : ""
            let kind: StepKind
            switch (manager, version) {
            case ("rvm", "downloads"): kind = .shell("\(source) && rvm cleanup archives && rvm cleanup sources")
            case ("rvm", "backup"): kind = .trash(item.paths)
            case ("rvm", _):
                let name = item.paths.first?.lastPathComponent ?? "ruby-\(version)"
                kind = .shell("\(source) && rvm remove \(shellQuote(name)) --gems")
            case ("rbenv", _): kind = .command(argv: ["rbenv", "uninstall", "-f", version])
            case ("mise", _): kind = .command(argv: ["mise", "uninstall", "ruby@\(version)"])
            default: kind = .command(argv: ["asdf", "uninstall", "ruby", version])
            }
            return [Step("Remove \(item.title)", kind, bytes: item.bytes, itemID: item.id)]
        }
    }
}
