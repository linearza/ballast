import Foundation

/// Python versions from pyenv, uv and mise, and the virtualenvs that conda, pipx,
/// Poetry, pipenv and hatch keep outside projects.
public struct PythonProvider: Provider {
    public init() {}
    public let id = "python"
    public let title = "Python"
    public let section = Section.toolchains
    public let symbol = "chevron.left.forwardslash.chevron.right"

    static let uvDir = ".local/share/uv/python"
    static let condaBases = ["miniforge3", "miniconda3", "anaconda3", "mambaforge", ".conda", "opt/miniconda3", "opt/anaconda3"]
    static let pipxDirs = [".local/pipx/venvs", ".local/share/pipx/venvs"]
    static let poetryDir = "Library/Caches/pypoetry/virtualenvs"
    static let pipenvDir = ".local/share/virtualenvs"
    static let hatchDir = "Library/Application Support/hatch/env/virtual"

    public func isPresent(_ env: Environment) async -> Bool {
        ([".pyenv/versions", ".venvs", Self.uvDir, Self.poetryDir, Self.pipenvDir, Self.hatchDir] + Self.pipxDirs
            + Self.condaBases.map { "\($0)/envs" }).contains { exists(env.path($0)) }
            || exists(miseInstalls(env, tool: "python"))
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        func version(_ folder: URL, _ v: String, id: String, title: String? = nil, detail: String, isDefault: Bool) {
            var badges = Set<Badge>()
            if isDefault { badges.insert(.isDefault) }
            if let pin = pinBadge(pins, pins.python, installed: v) { badges.insert(pin) }
            items.append(Item(id: id, title: title ?? "Python \(v)", detail: detail,
                              paths: [folder], bytes: 0, risk: .regenerable, badges: badges))
        }
        func venv(_ folder: URL, id: String, title: String, detail: String, risk: Risk) {
            items.append(Item(id: id, title: title, detail: detail, paths: [folder], bytes: 0, risk: risk))
        }

        let def = firstLine(env.path(".pyenv/version"))
        for v in subfolders(env.path(".pyenv/versions")) {
            version(env.path(".pyenv/versions/\(v)"), v, id: "python.pyenv.\(v)", detail: "pyenv", isDefault: v == def)
        }
        let mise = miseInstalls(env, tool: "python")
        let miseVersions = subfolders(mise)
        let miseDefault = miseGlobal(env, tools: ["python"], installed: miseVersions)
        for v in miseVersions {
            version(mise.appending(path: v), v, id: "python.mise.\(v)", detail: "mise", isDefault: v == miseDefault)
        }
        // uv names its folders implementation-version-platform: cpython-3.12.4-macos-aarch64-none.
        for name in subfolders(env.path(Self.uvDir)) {
            let parts = name.split(separator: "-").map(String.init)
            guard parts.count > 1 else { continue }
            let impl = parts[0] == "cpython" ? "Python" : parts[0] == "pypy" ? "PyPy" : parts[0]
            version(env.path("\(Self.uvDir)/\(name)"), parts[1], id: "python.uv.\(name)", title: "\(impl) \(parts[1])",
                    detail: "uv", isDefault: false)
        }

        for name in subfolders(env.path(".venvs")) {
            venv(env.path(".venvs/\(name)"), id: "python.venv.\(name)", title: "venv \(name)", detail: "~/.venvs", risk: .review)
        }
        var seen = Set<String>()
        for base in Self.condaBases {
            for name in subfolders(env.path("\(base)/envs")) {
                let id = seen.insert(name).inserted ? "python.conda.\(name)" : "python.conda.\(name)@\(base)"
                venv(env.path("\(base)/envs/\(name)"), id: id, title: "conda env \(name)", detail: base, risk: .review)
            }
        }
        for dir in Self.pipxDirs {
            for name in subfolders(env.path(dir)) {
                venv(env.path("\(dir)/\(name)"), id: "python.pipx.\(name)", title: name, detail: "pipx app", risk: .review)
            }
        }
        for name in subfolders(env.path(Self.poetryDir)) {
            venv(env.path("\(Self.poetryDir)/\(name)"), id: "python.poetry.\(name)", title: name,
                 detail: "Poetry virtualenv · rebuilt by poetry install", risk: .regenerable)
        }
        for name in subfolders(env.path(Self.pipenvDir)) {
            venv(env.path("\(Self.pipenvDir)/\(name)"), id: "python.pipenv.\(name)", title: name,
                 detail: "pipenv virtualenv · rebuilt by pipenv install", risk: .regenerable)
        }
        for name in subfolders(env.path(Self.hatchDir)) {
            venv(env.path("\(Self.hatchDir)/\(name)"), id: "python.hatch.\(name)", title: name,
                 detail: "hatch environments · rebuilt on next use", risk: .regenerable)
        }
        return await measured(items)
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        let conda: String? = if await env.runner.which("conda") != nil { "conda" } else {
            Self.condaBases.map { env.path("\($0)/bin/conda").path }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        let pipx = await env.runner.which("pipx") != nil
        var plan = planEach(ids, items: items, noun: "Python") { item in
            let parts = item.id.split(separator: ".", maxSplits: 2).map(String.init)
            let name = parts[2]
            let kind: StepKind = switch parts[1] {
            case "pyenv": .command(argv: ["pyenv", "uninstall", "-f", name])
            case "mise": .command(argv: ["mise", "uninstall", "python@\(name)"])
            case "uv" where name.hasPrefix("cpython-"): .command(argv: ["uv", "python", "uninstall", name.split(separator: "-")[1].description])
            case "uv": .command(argv: ["uv", "python", "uninstall", name])
            case "conda" where conda != nil: .command(argv: [conda!, "env", "remove", "-y", "-p", item.paths[0].path])
            case "pipx" where pipx: .command(argv: ["pipx", "uninstall", name])
            default: .trash(item.paths)
            }
            return [Step("Remove \(item.title)", kind, bytes: item.bytes, itemID: item.id)]
        }
        let venvs = items.filter { !ids.contains($0.id) && !Self.isVersion($0) }
        for item in items where ids.contains(item.id) && Self.isVersion(item) {
            guard let root = item.paths.first?.resolvingSymlinksInPath().path else { continue }
            let users = venvs.filter { venv in venv.paths.contains { Self.homes($0).contains { $0 == root || $0.hasPrefix(root + "/") } } }
            guard !users.isEmpty else { continue }
            let names = users.map { "\($0.title) (\($0.detail?.components(separatedBy: " · ").first ?? "virtualenv"))" }
            plan.dangers.append("\(item.title) runs \(names.joined(separator: ", ")). \(users.count == 1 ? "It stops" : "They stop") working until you reinstall \(users.count == 1 ? "it" : "them") with another Python.")
        }
        return plan
    }

    static func isVersion(_ item: Item) -> Bool {
        ["python.pyenv.", "python.mise.", "python.uv."].contains { item.id.hasPrefix($0) }
    }

    /// The Python each virtualenv in `folder` was made from, read from `pyvenv.cfg` (hatch keeps one per environment, a level down).
    static func homes(_ folder: URL) -> [String] {
        let cfgs = [folder.appending(path: "pyvenv.cfg")] + subfolders(folder).map { folder.appending(path: "\($0)/pyvenv.cfg") }
        return cfgs.compactMap { cfg in
            guard let text = try? String(contentsOf: cfg, encoding: .utf8) else { return nil }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == "home" { return URL(filePath: parts[1]).resolvingSymlinksInPath().path }
            }
            return nil
        }
    }
}
