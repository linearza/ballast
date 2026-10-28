import Foundation

/// Editors and AI coding tools: Cursor, VS Code, Windsurf and Claude's caches, old Claude Code
/// versions, Claude Code history for projects that no longer exist, opencode, Codex and Gemini.
public struct EditorsProvider: Provider {
    public init() { isRunning = { isAppRunning(bundleID: $0) } }
    init(isRunning: @escaping @Sendable (String) -> Bool) { self.isRunning = isRunning }
    /// Whether the app with this bundle id is open. Tests replace it, since the real apps may be open.
    let isRunning: @Sendable (String) -> Bool
    public let id = "editors"
    public let title = "AI tools and editors"
    public let section = Section.editors
    public let symbol = "sparkles.rectangle.stack"

    /// Electron apps share a layout in ~/Library/Application Support/<folder>.
    static let electron: [(key: String, name: String, folder: String, bundleID: String)] = [
        ("cursor", "Cursor", "Cursor", "com.todesktop.230313mzl4w4u92"),
        ("vscode", "VS Code", "Code", "com.microsoft.VSCode"),
        ("windsurf", "Windsurf", "Windsurf", "com.exafunction.windsurf"),
        ("claude-desktop", "Claude", "Claude", "com.anthropic.claudefordesktop"),
    ]
    static let cacheFolders = ["CachedData", "Cache", "Code Cache", "GPUCache", "logs", "CachedExtensionVSIXs",
                               "DawnGraphiteCache", "DawnWebGPUCache"]
    /// Plain folders: id suffix, title, path in home, risk.
    static let folders: [(id: String, title: String, rel: String, risk: Risk)] = [
        ("opencode.logs", "opencode logs", ".local/share/opencode/log", .regenerable),
        ("opencode.cache", "opencode cache", ".cache/opencode", .regenerable),
        ("opencode.snapshots", "opencode snapshots", ".local/share/opencode/snapshot", .review),
        ("opencode.sessions", "opencode sessions", ".local/share/opencode/storage", .yourData),
        ("codex.logs", "Codex logs", ".codex/log", .regenerable),
        ("codex.sessions", "Codex sessions", ".codex/sessions", .yourData),
        ("gemini.tmp", "Gemini CLI temporary files", ".gemini/tmp", .regenerable),
    ]
    static let claudeVersions = ".local/share/claude/versions"

    public func isPresent(_ env: Environment) async -> Bool {
        Self.electron.contains { exists(env.path("Library/Application Support/\($0.folder)")) }
            || Self.folders.contains { exists(env.path($0.rel)) }
            || exists(env.path(Self.claudeVersions)) || exists(env.path(".claude/projects"))
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        for app in Self.electron {
            let base = env.path("Library/Application Support/\(app.folder)")
            guard exists(base) else { continue }
            let running: Set<Badge> = isRunning(app.bundleID) ? [.running] : []
            let caches = Self.cacheFolders.map { base.appending(path: $0) }.filter(exists)
            if !caches.isEmpty {
                items.append(Item(id: "editors.\(app.key).cache", title: "\(app.name) caches", detail: "Rebuilt when \(app.name) next opens",
                                  paths: caches, bytes: 0, risk: .regenerable, badges: running))
            }
            let workspaces = base.appending(path: "User/workspaceStorage")
            if exists(workspaces) {
                items.append(Item(id: "editors.\(app.key).workspaces", title: "\(app.name) workspace storage",
                                  detail: "Per-project editor state, including chat history in some editors", paths: [workspaces],
                                  bytes: 0, risk: .review, badges: running))
            }
            let state = base.appending(path: "User/globalStorage/state.vscdb")
            if exists(state) {
                items.append(Item(id: "editors.\(app.key).state", title: "\(app.name) settings and chats",
                                  detail: "Shown for its size. Clear chats from inside \(app.name)", paths: [state],
                                  bytes: 0, risk: .yourData))
            }
            let vms = base.appending(path: "vm_bundles")
            if exists(vms) {
                items.append(Item(id: "editors.\(app.key).vms", title: "\(app.name) VM bundles", detail: "Downloaded again when needed",
                                  paths: [vms], bytes: 0, risk: .review, badges: running))
            }
        }
        items += claudeCodeVersions(env)
        items += orphanedClaudeProjects(env)
        for f in Self.folders where exists(env.path(f.rel)) {
            items.append(Item(id: "editors.\(f.id)", title: f.title, detail: "~/\(f.rel)", paths: [env.path(f.rel)], bytes: 0, risk: f.risk))
        }
        return await measured(items)
    }

    /// Claude Code keeps every version it updates to. The newest and the one `claude` runs stay.
    func claudeCodeVersions(_ env: Environment) -> [Item] {
        let dir = env.path(Self.claudeVersions)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.first?.isNumber == true }
            .sorted { compareVersions($0, $1) == .orderedAscending }
        let inUse = (try? FileManager.default.destinationOfSymbolicLink(atPath: env.path(".local/bin/claude").path))
            .map { URL(filePath: $0).lastPathComponent }
        return names.dropLast().filter { $0 != inUse }.map { v in
            Item(id: "editors.claude.version.\(v)", title: "Claude Code \(v)", detail: "An older version kept after updating",
                 paths: [dir.appending(path: v)], bytes: 0, risk: .regenerable)
        }
    }

    /// Conversation history for projects whose folder no longer exists.
    func orphanedClaudeProjects(_ env: Environment) -> [Item] {
        let root = env.path(".claude/projects")
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        return dirs.compactMap { name in
            let dir = root.appending(path: name)
            let logs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
            guard let cwd = logs.lazy.compactMap({ projectFolder(dir.appending(path: $0)) }).first, !exists(URL(filePath: cwd)) else { return nil }
            return Item(id: "editors.claude.project.\(name)", title: "Claude Code history for \(URL(filePath: cwd).lastPathComponent)",
                        detail: "\(cwd) no longer exists", paths: [dir], bytes: 0, risk: .review)
        }
    }

    /// The `cwd` of the first message that has one, from the first 64 KB of a session log.
    func projectFolder(_ log: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.contains("\"cwd\""), let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cwd = json["cwd"] as? String, cwd.hasPrefix("/") else { continue }
            return cwd
        }
        return nil
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = Plan()
        for item in items where ids.contains(item.id) {
            if item.id.hasSuffix(".state") {
                plan.refusals.append(Refusal(itemID: item.id, reason: "Holds your settings and chats. Clear them from inside the app"))
                continue
            }
            if item.badges.contains(.running) {
                plan.refusals.append(Refusal(itemID: item.id, reason: "The app is open. Quit it first"))
                continue
            }
            if item.risk == .yourData { plan.warnings.append("\(item.title) can't be recovered once the Trash is emptied.") }
            plan.steps.append(Step("Move \(item.title) to the Trash", .trash(item.paths), bytes: item.bytes, itemID: item.id))
        }
        return plan
    }
}
