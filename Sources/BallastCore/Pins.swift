import Foundation

/// Folders that usually hold code, checked on first run.
let candidateRootNames = ["Projects", "code", "dev", "src", "Developer", "work", "repos"]

/// Candidate folders in home that hold at least two git repositories.
public func detectProjectRoots(home: URL) -> [URL] {
    let fm = FileManager.default
    return candidateRootNames.map { home.appending(path: $0) }.filter { root in
        guard let children = try? fm.contentsOfDirectory(atPath: root.path) else { return false }
        let repos = children.filter { fm.fileExists(atPath: root.appending(path: $0).appending(path: ".git").path) }
        return repos.count >= 2
    }
}

/// Versions that projects ask for, each with the projects asking. Keys are as
/// written in the project, minus `v` / `ruby-` prefixes.
public struct Pins: Sendable, Equatable {
    public var ruby: [String: [String]] = [:]
    public var node: [String: [String]] = [:]
    public var python: [String: [String]] = [:]

    public init(ruby: [String: [String]] = [:], node: [String: [String]] = [:], python: [String: [String]] = [:]) {
        self.ruby = ruby
        self.node = node
        self.python = python
    }

    /// The projects whose pin in `map` matches an installed version, sorted.
    public func pinners(of map: [String: [String]], installed: String) -> [String] {
        Set(map.filter { versionMatches(pin: $0.key, installed: installed) }.flatMap(\.value)).sorted()
    }
}

/// Whether a pinned version selects an installed one. A shorter pin matches
/// any version it's a prefix of, component by component: `18.19` matches `18.19.1`.
public func versionMatches(pin: String, installed: String) -> Bool {
    let p = versionComponents(pin), i = versionComponents(installed)
    guard !p.isEmpty, p.count <= i.count else { return false }
    return Array(i.prefix(p.count)) == p
}

func normalizeVersion(_ s: String) -> String {
    var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["ruby-", "node-", "python-", "v"] where v.hasPrefix(prefix) { v.removeFirst(prefix.count) }
    return v
}

private func versionComponents(_ s: String) -> [String] {
    normalizeVersion(s).split(separator: ".").map(String.init)
}

/// Reads a node version from package.json: a bare version, `18.x`, `^18` or `~18.19`.
/// Open ranges like `>=18` don't pin anything.
func pinnedNodeVersion(_ raw: String) -> String? {
    var v = raw.trimmingCharacters(in: .whitespaces)
    if v.hasPrefix("^") || v.hasPrefix("~") { v.removeFirst() }
    v = normalizeVersion(v)
    let parts = v.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let kept = parts.prefix { $0 != "x" && $0 != "*" }
    guard !kept.isEmpty, kept.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
    return kept.joined(separator: ".")
}

/// The `[tools]` table of a mise config: `node = "22"`, `python = ["3.12", "3.11"]` or
/// `ruby = { version = "3.3" }`. Keys are tool names as written (`node`, `nodejs`, `"ruby"`).
func parseMiseTools(_ toml: String) -> [String: [String]] {
    var tools: [String: [String]] = [:]
    var inTools = false
    for raw in toml.split(whereSeparator: \.isNewline) {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.hasPrefix("[") {
            inTools = line == "[tools]"
            continue
        }
        guard inTools, let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        var value = String(line[line.index(after: eq)...])
        if let m = value.firstMatch(of: /version\s*=\s*["']([^"']+)["']/) { value = "\"\(m.1)\"" }
        let versions = value.matches(of: /["']([^"']+)["']/).map { String($0.1) }
        if !key.isEmpty, !versions.isEmpty { tools[key, default: []] += versions }
    }
    return tools
}

/// Which pin map a mise or asdf tool name belongs to.
func pinMap(forTool tool: String) -> WritableKeyPath<Pins, [String: [String]]>? {
    switch tool {
    case "ruby": \.ruby
    case "node", "nodejs": \.node
    case "python": \.python
    default: nil
    }
}

let miseConfigNames = ["mise.toml", ".mise.toml", "mise.local.toml", ".mise.local.toml"]

private let skippedFolders: Set<String> = ["node_modules", ".git", "vendor"]

public func scanPins(roots: [URL], maxDepth: Int = 3) -> Pins {
    var pins = Pins()
    func add(_ map: WritableKeyPath<Pins, [String: [String]]>, _ version: String?, _ project: String) {
        guard let version, !version.isEmpty else { return }
        let key = normalizeVersion(version)
        if pins[keyPath: map][key, default: []].contains(project) == false {
            pins[keyPath: map][key, default: []].append(project)
        }
    }

    func visit(_ dir: URL, project: String, depth: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let read = { (name: String) in try? String(contentsOf: dir.appending(path: name), encoding: .utf8) }
        let firstLine = { (name: String) in read(name)?.split(whereSeparator: \.isNewline).first.map(String.init) }

        if names.contains(".ruby-version") { add(\.ruby, firstLine(".ruby-version"), project) }
        if names.contains(".nvmrc") { add(\.node, firstLine(".nvmrc"), project) }
        if names.contains(".node-version") { add(\.node, firstLine(".node-version"), project) }
        if names.contains(".python-version") { add(\.python, firstLine(".python-version"), project) }
        if names.contains(".tool-versions"), let text = read(".tool-versions") {
            for line in text.split(whereSeparator: \.isNewline) {
                let words = line.split(separator: " ").map(String.init)
                guard let tool = words.first else { continue }
                if let map = pinMap(forTool: tool) { words.dropFirst().forEach { add(map, $0, project) } }
            }
        }
        for name in miseConfigNames where names.contains(name) {
            for (tool, versions) in parseMiseTools(read(name) ?? "") {
                // `latest` and `lts` don't pin a version.
                if let map = pinMap(forTool: tool) { versions.filter { $0.first?.isNumber == true }.forEach { add(map, $0, project) } }
            }
        }
        if names.contains("Gemfile"), let text = read("Gemfile"),
           let m = text.firstMatch(of: /(?m)^\s*ruby\s+["']([^"']+)["']/) {
            var v = String(m.1).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("~>") {
                v = v.dropFirst(2).trimmingCharacters(in: .whitespaces)
                v = v.split(separator: ".").dropLast().joined(separator: ".")
            }
            if v.first?.isNumber == true { add(\.ruby, v, project) }
        }
        if names.contains("package.json"), let data = read("package.json")?.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let engines = json["engines"] as? [String: Any], let n = engines["node"] as? String {
                add(\.node, pinnedNodeVersion(n), project)
            }
            if let volta = json["volta"] as? [String: Any], let n = volta["node"] as? String {
                add(\.node, pinnedNodeVersion(n), project)
            }
        }

        guard depth < maxDepth else { return }
        for name in names where !skippedFolders.contains(name) && !name.hasPrefix(".") {
            let child = dir.appending(path: name)
            var st = stat()
            guard lstat(child.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            visit(child, project: project.isEmpty ? name : "\(project)/\(name)", depth: depth + 1)
        }
    }

    for root in roots { visit(root, project: "", depth: 0) }
    return pins
}
