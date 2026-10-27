import Foundation

/// Python versions from pyenv and mise, and virtualenvs kept in ~/.venvs.
public struct PythonProvider: Provider {
    public init() {}
    public let id = "python"
    public let title = "Python"
    public let section = Section.toolchains
    public let symbol = "chevron.left.forwardslash.chevron.right"

    public func isPresent(_ env: Environment) async -> Bool {
        exists(env.path(".pyenv/versions")) || exists(env.path(".venvs")) || exists(miseInstalls(env, tool: "python"))
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        let def = firstLine(env.path(".pyenv/version"))
        for v in subfolders(env.path(".pyenv/versions")) {
            var badges = Set<Badge>()
            if v == def { badges.insert(.isDefault) }
            if let pin = pinBadge(pins, pins.python, installed: v) { badges.insert(pin) }
            items.append(Item(id: "python.pyenv.\(v)", title: "Python \(v)", detail: "pyenv",
                              paths: [env.path(".pyenv/versions/\(v)")], bytes: 0, risk: .regenerable, badges: badges))
        }
        let mise = miseInstalls(env, tool: "python")
        let miseVersions = subfolders(mise)
        let miseDefault = miseGlobal(env, tools: ["python"], installed: miseVersions)
        for v in miseVersions {
            var badges = Set<Badge>()
            if v == miseDefault { badges.insert(.isDefault) }
            if let pin = pinBadge(pins, pins.python, installed: v) { badges.insert(pin) }
            items.append(Item(id: "python.mise.\(v)", title: "Python \(v)", detail: "mise",
                              paths: [mise.appending(path: v)], bytes: 0, risk: .regenerable, badges: badges))
        }
        for name in subfolders(env.path(".venvs")) {
            items.append(Item(id: "python.venv.\(name)", title: "venv \(name)", detail: "~/.venvs",
                              paths: [env.path(".venvs/\(name)")], bytes: 0, risk: .review))
        }
        return await measured(items)
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        planEach(ids, items: items, noun: "Python") { item in
            let parts = item.id.split(separator: ".", maxSplits: 2).map(String.init)
            let kind: StepKind = switch parts[1] {
            case "pyenv": .command(argv: ["pyenv", "uninstall", "-f", parts[2]])
            case "mise": .command(argv: ["mise", "uninstall", "python@\(parts[2])"])
            default: .trash(item.paths)
            }
            return [Step("Remove \(item.title)", kind, bytes: item.bytes, itemID: item.id)]
        }
    }
}
