import Foundation

/// Leftovers inside your projects: `node_modules` and other build output, and git worktrees.
public struct ProjectLeftoversProvider: Provider {
    public init(idleDays: Int = 60, minBytes: Int64 = 1_000_000) {
        self.idleDays = idleDays
        self.minBytes = minBytes
    }
    public let id = "projects"
    public let title = "Project leftovers"
    public let section = Section.projects
    public let symbol = "folder"

    /// node_modules in projects quiet for this long count as safe to remove.
    let idleDays: Int
    /// Build output smaller than this isn't worth a line in the list.
    let minBytes: Int64

    public func isPresent(_ env: Environment) async -> Bool {
        env.projectRoots.contains(where: exists)
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var builds: [Item] = []
        for found in buildOutput(env.projectRoots) where await !isTracked(found.url, env: env) {
            builds.append(await buildItem(found.url, kind: found.kind, env: env))
        }
        var items = await measured(builds).filter { $0.bytes >= minBytes || $0.sizeIsPartial }
        var worktrees: [Item] = []
        for repo in repos(env.projectRoots) {
            worktrees += await worktreeItems(repo, env: env)
        }
        items += await measured(worktrees)
        return items
    }

    // MARK: Build output

    /// A folder a build or package manager makes inside a project, found by its name next to a marker file.
    struct BuildKind: Sendable {
        var name: String
        var label: String
        /// Paths relative to the project; any one present confirms it. Empty means the name is enough.
        var markers: [String]
        /// Some output may be what the project ships, so it never counts as safe.
        var alwaysReview = false
    }

    static let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
    static let buildKinds: [BuildKind] = [
        BuildKind(name: "node_modules", label: "npm packages", markers: []),
        BuildKind(name: "target", label: "Rust build", markers: ["Cargo.toml"]),
        BuildKind(name: ".venv", label: "Python virtualenv", markers: [".venv/pyvenv.cfg"]),
        BuildKind(name: "venv", label: "Python virtualenv", markers: ["venv/pyvenv.cfg"]),
        BuildKind(name: ".next", label: "Next.js build", markers: ["package.json"]),
        BuildKind(name: ".nuxt", label: "Nuxt build", markers: ["package.json"]),
        BuildKind(name: ".turbo", label: "Turborepo cache", markers: ["package.json"]),
        BuildKind(name: ".svelte-kit", label: "SvelteKit build", markers: ["package.json"]),
        BuildKind(name: ".parcel-cache", label: "Parcel cache", markers: ["package.json"]),
        BuildKind(name: ".angular", label: "Angular cache", markers: ["package.json"]),
        BuildKind(name: "Pods", label: "CocoaPods", markers: ["Podfile"]),
        BuildKind(name: ".gradle", label: "Gradle cache", markers: gradle),
        BuildKind(name: "build", label: "Gradle build", markers: gradle),
        BuildKind(name: "_build", label: "Elixir build", markers: ["mix.exs"]),
        BuildKind(name: "deps", label: "Elixir dependencies", markers: ["mix.exs"]),
        BuildKind(name: ".dart_tool", label: "Dart tool cache", markers: ["pubspec.yaml"]),
        BuildKind(name: "build", label: "Build output", markers: ["package.json"], alwaysReview: true),
        BuildKind(name: "dist", label: "Build output", markers: ["package.json"], alwaysReview: true),
    ]
    static let buildNames = Set(buildKinds.map(\.name))

    /// Build output up to four levels under the roots, without descending into any of it or into hidden folders.
    func buildOutput(_ roots: [URL], maxDepth: Int = 4) -> [(url: URL, kind: BuildKind)] {
        let fm = FileManager.default
        var found: [(url: URL, kind: BuildKind)] = []
        func isDir(_ url: URL) -> Bool {
            var st = stat()
            return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }
        func visit(_ dir: URL, depth: Int) {
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            var claimed = Set<String>()
            for name in names where Self.buildNames.contains(name) && isDir(dir.appending(path: name)) {
                if let kind = Self.buildKinds.first(where: { k in
                    k.name == name && (k.markers.isEmpty || k.markers.contains { exists(dir.appending(path: $0)) })
                }) {
                    found.append((dir.appending(path: name), kind))
                    claimed.insert(name)
                }
            }
            guard depth < maxDepth else { return }
            for name in names where !name.hasPrefix(".") && !claimed.contains(name) && name != "node_modules" && isDir(dir.appending(path: name)) {
                visit(dir.appending(path: name), depth: depth + 1)
            }
        }
        roots.forEach { visit($0, depth: 1) }
        return found
    }

    /// A folder git tracks files in is part of the project (some teams commit Pods or dist), not a leftover.
    func isTracked(_ folder: URL, env: Environment) async -> Bool {
        let r = await env.runner.run(["git", "-C", folder.deletingLastPathComponent().path, "ls-files", "--", folder.lastPathComponent],
                                     timeout: .seconds(10))
        return r.ok && !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func buildItem(_ url: URL, kind: BuildKind, env: Environment) async -> Item {
        let project = url.deletingLastPathComponent()
        let last = await lastActivity(project, env: env)
        let idle = last.map { env.now().timeIntervalSince($0) >= Double(idleDays) * 86_400 } ?? true
        let name = project.lastPathComponent
        let when = last.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "unknown"
        let id = kind.name == "node_modules" ? "project.nm.\(url.path)" : "project.build.\(url.path)"
        let detail = kind.name == "node_modules" ? "Last activity \(when)" : "\(kind.label) · last activity \(when)"
        return Item(id: id, title: "\(name) \(kind.name)", detail: detail,
                    paths: [url], bytes: 0, risk: idle && !kind.alwaysReview ? .regenerable : .review,
                    badges: idle ? [] : last.map { [.lastUsed($0)] } ?? [])
    }

    /// The last commit date, or the newest top-level file when the project isn't a repo. Build output doesn't count.
    func lastActivity(_ project: URL, env: Environment) async -> Date? {
        let r = await env.runner.run(["git", "-C", project.path, "log", "-1", "--format=%cI"], timeout: .seconds(10))
        if r.ok, let d = ISO8601DateFormatter().date(from: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return d
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []
        return names.filter { !Self.buildNames.contains($0) }.compactMap { name in
            try? FileManager.default.attributesOfItem(atPath: project.appending(path: name).path)[.modificationDate] as? Date
        }.max()
    }

    // MARK: Worktrees

    /// Repositories (a `.git` folder, not a worktree's `.git` file) up to three levels under the roots.
    func repos(_ roots: [URL], maxDepth: Int = 3) -> [URL] {
        var found: [URL] = []
        func visit(_ dir: URL, depth: Int) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.appending(path: ".git").path, isDirectory: &isDir), isDir.boolValue {
                found.append(dir)
                return
            }
            guard depth < maxDepth else { return }
            for name in subfolders(dir) where !name.hasPrefix(".") && name != "node_modules" {
                visit(dir.appending(path: name), depth: depth + 1)
            }
        }
        roots.forEach { visit($0, depth: 0) }
        return found
    }

    func worktreeItems(_ repo: URL, env: Environment) async -> [Item] {
        let list = await env.runner.run(["git", "-C", repo.path, "worktree", "list", "--porcelain"], timeout: .seconds(10))
        guard list.ok else { return [] }
        let trees = parseWorktrees(list.stdout).dropFirst()
        guard !trees.isEmpty else { return [] }
        let prs = await pullRequests(repo, env: env)

        var items: [Item] = []
        for t in trees where exists(URL(filePath: t.path)) {
            var badges = Set<Badge>()
            let status = await env.runner.run(["git", "-C", t.path, "status", "--porcelain"], timeout: .seconds(20))
            let dirty = status.stdout.split(whereSeparator: \.isNewline).count
            if dirty > 0 { badges.insert(.uncommitted(dirty)) }
            let ahead = await env.runner.run(["git", "-C", t.path, "rev-list", "--count", "@{u}..HEAD"], timeout: .seconds(10))
            if ahead.ok, let n = Int(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
                badges.insert(.unpushed(n))
            }
            if let branch = t.branch {
                if let prs {
                    if prs[branch]?.contains("OPEN") == true { badges.insert(.openPR) }
                    else if prs[branch]?.contains("MERGED") == true { badges.insert(.mergedPR) }
                } else if await upstreamGone(repo, branch: branch, env: env) {
                    badges.insert(.mergedPR)
                }
            }
            let clean = dirty == 0 && !badges.contains { if case .unpushed = $0 { true } else { false } }
            items.append(Item(id: "project.wt.\(t.path)", title: "\(repo.lastPathComponent) worktree \(t.branch ?? URL(filePath: t.path).lastPathComponent)",
                              detail: t.path, paths: [URL(filePath: t.path)], bytes: 0,
                              risk: badges.contains(.mergedPR) && clean ? .regenerable : .review, badges: badges))
        }
        return items
    }

    /// Branch name → PR states, from one `gh` call per repo. Nil when `gh` isn't installed or fails.
    func pullRequests(_ repo: URL, env: Environment) async -> [String: Set<String>]? {
        guard await env.runner.which("gh") != nil else { return nil }
        let r = await env.runner.shell("cd \(shellQuote(repo.path)) && gh pr list --state all --limit 1000 --json headRefName,state",
                                       timeout: .seconds(30))
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [String: Set<String>] = [:]
        for row in rows {
            if let head = row["headRefName"] as? String, let state = row["state"] as? String { out[head, default: []].insert(state) }
        }
        return out
    }

    /// The branch tracked a remote branch whose ref is gone. Uses refs as they are; never fetches.
    func upstreamGone(_ repo: URL, branch: String, env: Environment) async -> Bool {
        let remote = await env.runner.run(["git", "-C", repo.path, "config", "branch.\(branch).remote"], timeout: .seconds(5))
        let merge = await env.runner.run(["git", "-C", repo.path, "config", "branch.\(branch).merge"], timeout: .seconds(5))
        guard remote.ok, merge.ok else { return false }
        let name = merge.stdout.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "refs/heads/", with: "")
        let ref = "refs/remotes/\(remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines))/\(name)"
        return !(await env.runner.run(["git", "-C", repo.path, "rev-parse", "--verify", "--quiet", ref], timeout: .seconds(5))).ok
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = Plan()
        var prune: [String] = []
        for id in ids {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            guard id.hasPrefix("project.wt."), let path = item.paths.first else {
                plan.steps.append(Step("Move \(item.title) to the Trash", .trash(item.paths), bytes: item.bytes, itemID: id))
                continue
            }
            if item.badges.contains(where: { if case .uncommitted = $0 { true } else { false } }) {
                plan.refusals.append(Refusal(itemID: id, reason: "Has uncommitted changes"))
                continue
            }
            if let w = inUseWarning(item, noun: "worktree") { plan.dangers.append(w) }
            guard let repo = mainRepo(of: path) else {
                plan.refusals.append(Refusal(itemID: id, reason: "Can't find the repository this worktree belongs to"))
                continue
            }
            plan.steps.append(Step("Remove worktree \(path.lastPathComponent)",
                                   .command(argv: ["git", "-C", repo, "worktree", "remove", path.path]), bytes: item.bytes, itemID: id))
            if !prune.contains(repo) { prune.append(repo) }
        }
        for repo in prune {
            plan.steps.append(Step("Tidy git's worktree records", .command(argv: ["git", "-C", repo, "worktree", "prune"])))
        }
        return plan
    }

    /// A worktree's `.git` file reads `gitdir: <repo>/.git/worktrees/<name>`, relative to the worktree
    /// when git's `worktree.useRelativePaths` is on.
    func mainRepo(of worktree: URL) -> String? {
        guard let line = firstLine(worktree.appending(path: ".git")), line.hasPrefix("gitdir: ") else { return nil }
        let raw = String(line.dropFirst(8))
        let gitdir = raw.hasPrefix("/") ? URL(filePath: raw) : worktree.appending(path: raw)
        let path = gitdir.standardizedFileURL.path
        guard let r = path.range(of: "/.git/worktrees/") else { return nil }
        return String(path[..<r.lowerBound])
    }
}

struct Worktree: Equatable {
    var path: String
    var branch: String?
}

func parseWorktrees(_ porcelain: String) -> [Worktree] {
    porcelain.components(separatedBy: "\n\n").compactMap { block in
        var tree: Worktree?
        for line in block.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("worktree ") { tree = Worktree(path: String(line.dropFirst(9))) }
            if line.hasPrefix("branch ") { tree?.branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
        }
        return tree
    }
}
