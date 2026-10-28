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
        return planEach(ids, items: items, noun: "Python") { item in
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
    }
}
