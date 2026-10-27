import Foundation

/// Leftovers inside your projects: `node_modules` folders and git worktrees.
public struct ProjectLeftoversProvider: Provider {
    public init(idleDays: Int = 60) { self.idleDays = idleDays }
    public let id = "projects"
    public let title = "Project leftovers"
    public let section = Section.projects
    public let symbol = "folder"

    /// node_modules in projects quiet for this long count as safe to remove.
    let idleDays: Int

    public func isPresent(_ env: Environment) async -> Bool {
        env.projectRoots.contains(where: exists)
    }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] {
        var items: [Item] = []
        for nm in nodeModules(env.projectRoots) {
            items.append(await nodeModulesItem(nm, env: env))
        }
        for repo in repos(env.projectRoots) {
            items += await worktreeItems(repo, env: env)
        }
        return await measured(items)
    }

    // MARK: node_modules

    /// Every `node_modules` up to four levels under the roots, without descending into one.
    func nodeModules(_ roots: [URL], maxDepth: Int = 4) -> [URL] {
        var found: [URL] = []
        func visit(_ dir: URL, depth: Int) {
            for name in subfolders(dir) where !name.hasPrefix(".") {
                let url = dir.appending(path: name)
                if name == "node_modules" { found.append(url) } else if depth < maxDepth { visit(url, depth: depth + 1) }
            }
        }
        roots.forEach { visit($0, depth: 1) }
        return found
    }

    func nodeModulesItem(_ nm: URL, env: Environment) async -> Item {
        let project = nm.deletingLastPathComponent()
        let last = await lastActivity(project, env: env)
        let idle = last.map { env.now().timeIntervalSince($0) >= Double(idleDays) * 86_400 } ?? true
        let name = project.lastPathComponent
        let when = last.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "unknown"
        return Item(id: "project.nm.\(nm.path)", title: "\(name) node_modules", detail: "Last activity \(when)",
                    paths: [nm], bytes: 0, risk: idle ? .regenerable : .review,
                    badges: idle ? [] : last.map { [.lastUsed($0)] } ?? [])
    }

    /// The last commit date, or the newest top-level file when the project isn't a repo.
    func lastActivity(_ project: URL, env: Environment) async -> Date? {
        let r = await env.runner.run(["git", "-C", project.path, "log", "-1", "--format=%cI"], timeout: .seconds(10))
        if r.ok, let d = ISO8601DateFormatter().date(from: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return d
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []
        return names.filter { $0 != "node_modules" }.compactMap { name in
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
            if let w = inUseWarning(item, noun: "worktree") { plan.warnings.append(w) }
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

    /// A worktree's `.git` file reads `gitdir: <repo>/.git/worktrees/<name>`.
    func mainRepo(of worktree: URL) -> String? {
        guard let line = firstLine(worktree.appending(path: ".git")), line.hasPrefix("gitdir: "),
              let r = line.dropFirst(8).range(of: "/.git/worktrees/") else { return nil }
        return String(line.dropFirst(8)[..<r.lowerBound])
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
