import Foundation
import Testing
@testable import BallastCore

/// Runs git for real against fixture repos, with a fixed identity and dates.
@discardableResult
func git(_ dir: URL, _ args: String..., date: String = "2026-10-20T10:00:00Z") -> String {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/git")
    p.arguments = ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"] + args
    p.environment = ["GIT_COMMITTER_DATE": date, "GIT_AUTHOR_DATE": date, "HOME": dir.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

@Suite struct ProjectLeftoversTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!

    func repo(_ f: Fixture, _ rel: String, date: String = "2026-10-20T10:00:00Z") -> URL {
        let dir = f.file("\(rel)/README.md", contents: "hi").deletingLastPathComponent()
        git(dir, "init", "-q")
        git(dir, "add", ".")
        git(dir, "commit", "-q", "-m", "first", date: date)
        return dir
    }

    func runner(gh: String? = nil) -> FakeRunner {
        FakeRunner([:], tools: gh == nil ? [] : ["gh"], passthrough: ["git"])
    }

    @Test func idleNodeModulesRegenerable() async throws {
        let f = Fixture()
        repo(f, "Projects/old", date: "2026-01-01T10:00:00Z")
        f.file("Projects/old/node_modules/a/index.js", bytes: 10_000)
        let items = await ProjectLeftoversProvider().scan(f.env(runner: runner(), now: now), pins: Pins())
        let nm = try #require(items.first { $0.id.hasPrefix("project.nm.") })
        #expect(nm.risk == .regenerable)
        #expect(!nm.inUse)
        #expect(nm.bytes >= 10_000)
        #expect(nm.detail?.contains("2026") == true)
    }

    @Test func activeNodeModulesReview() async throws {
        let f = Fixture()
        repo(f, "Projects/new", date: "2026-10-20T10:00:00Z")
        f.file("Projects/new/node_modules/a/index.js", bytes: 10_000)
        let items = await ProjectLeftoversProvider().scan(f.env(runner: runner(), now: now), pins: Pins())
        let nm = try #require(items.first { $0.id.hasPrefix("project.nm.") })
        #expect(nm.risk == .review)
        #expect(nm.badges.contains { if case .lastUsed = $0 { true } else { false } })
    }

    @Test func nonRepoUsesNewestFileDate() async throws {
        let f = Fixture()
        f.file("Projects/loose/package.json", contents: "{}", modified: ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z"))
        f.file("Projects/loose/node_modules/a/index.js", bytes: 100)
        let items = await ProjectLeftoversProvider().scan(f.env(runner: runner(), now: now), pins: Pins())
        #expect(items.first { $0.id.hasPrefix("project.nm.") }?.risk == .regenerable)
    }

    @Test func nestedNodeModulesIgnored() async throws {
        let f = Fixture()
        f.file("Projects/app/package.json", contents: "{}")
        f.file("Projects/app/node_modules/dep/node_modules/inner/x.js", bytes: 100)
        let items = await ProjectLeftoversProvider().scan(f.env(runner: runner(), now: now), pins: Pins())
        #expect(items.filter { $0.id.hasPrefix("project.nm.") }.count == 1)
    }

    @Test func dirtyWorktreeRefused() async throws {
        let f = Fixture()
        let r = repo(f, "Projects/app")
        let wt = f.url("Projects/app-feature")
        git(r, "worktree", "add", "-q", "-b", "feature", wt.path)
        f.file("Projects/app-feature/scratch.txt", contents: "wip")
        let env = f.env(runner: runner(), now: now)
        let p = ProjectLeftoversProvider()
        let items = await p.scan(env, pins: Pins())
        let w = try #require(items.first { $0.id.hasPrefix("project.wt.") })
        #expect(w.badges.contains(.uncommitted(1)))
        #expect(w.risk == .review)
        let plan = await p.plan([w.id], items: items, env: env)
        #expect(plan.steps.isEmpty)
        #expect(plan.refusals.first?.reason == "Has uncommitted changes")
    }

    @Test func mergedCleanWorktreePlanned() async throws {
        let f = Fixture()
        let r = repo(f, "Projects/app")
        let wt = f.url("Projects/app-done")
        git(r, "worktree", "add", "-q", "-b", "done", wt.path)
        let fake = runner(gh: "gh")
        fake.responses["cd \(shellQuote(r.path)) && gh pr list --state all --limit 1000 --json headRefName,state"] =
            FakeRunner.out(#"[{"headRefName":"done","state":"MERGED"},{"headRefName":"other","state":"OPEN"}]"#)
        let env = f.env(runner: fake, now: now)
        let p = ProjectLeftoversProvider()
        let items = await p.scan(env, pins: Pins())
        let w = try #require(items.first { $0.id.hasPrefix("project.wt.") })
        #expect(w.badges.contains(.mergedPR))
        #expect(w.risk == .regenerable)
        let plan = await p.plan([w.id], items: items, env: env)
        #expect(plan.refusals.isEmpty)
        let argvs = plan.steps.compactMap { if case .command(let a) = $0.kind { a } else { nil } }
        #expect(argvs.contains { $0.starts(with: ["git", "-C"]) && $0.suffix(2).first == "remove" })
        #expect(argvs.last?.suffix(2) == ["worktree", "prune"])
        #expect(fake.calls.filter { $0.contains("gh pr list") }.count == 1)
    }

    @Test func noGhFallback() async throws {
        let f = Fixture()
        let r = repo(f, "Projects/app")
        let wt = f.url("Projects/app-gone")
        git(r, "worktree", "add", "-q", "-b", "gone", wt.path)
        // The branch tracked a remote branch that has since been deleted.
        git(r, "config", "branch.gone.remote", "origin")
        git(r, "config", "branch.gone.merge", "refs/heads/gone")
        let fake = runner()
        let items = await ProjectLeftoversProvider().scan(f.env(runner: fake, now: now), pins: Pins())
        let w = try #require(items.first { $0.id.hasPrefix("project.wt.") })
        #expect(w.badges.contains(.mergedPR))
        #expect(!fake.calls.contains { $0.contains("gh ") })
    }
}
