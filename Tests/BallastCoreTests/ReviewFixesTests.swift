import Foundation
import Testing
@testable import BallastCore

/// Fixes from the 0.1.1 security and feature review.
@Suite struct ReviewFixesTests {
    func plist(_ bid: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>\(bid)</string></dict></plist>
        """
    }

    func run(_ f: Fixture, _ steps: [Step], items: [Item]) async -> [StepResult] {
        await Executor(env: f.env(), logURL: f.url("state/actions.log"))
            .run(Plan(steps: steps), provider: StubProvider(), items: items, pins: Pins()) { _ in }
    }

    // MARK: Executor

    @Test func laterStepsOfAnItemSkipAfterAFailure() async {
        let f = Fixture()
        let leftovers = f.file("Library/Caches/com.example.x/data", bytes: 10)
        let item = Item(id: "app", title: "X", paths: [], bytes: 0, risk: .review)
        let results = await run(f, [Step("Uninstall", .command(argv: ["nope"]), itemID: "app"),
                                    Step("Leftovers", .trash([leftovers]), itemID: "app")], items: [item])
        #expect(FileManager.default.fileExists(atPath: leftovers.path))
        guard case .skipped = results.last?.outcome else { Issue.record("expected skipped, got \(String(describing: results.last?.outcome))"); return }
    }

    @Test func readOnlyFolderOfYoursIsTrashed() async {
        // Go's module cache is read-only on purpose; it's still yours to move.
        let f = Fixture()
        let mod = f.dir("go/pkg/mod")
        f.file("go/pkg/mod/x@v1/a.go", bytes: 10)
        chmod(mod.path, 0o555)
        let results = await run(f, [Step("Trash", .trash([mod]), itemID: "a")],
                                items: [Item(id: "a", title: "Go", paths: [mod], bytes: 0, risk: .regenerable)])
        #expect(results.first?.outcome == .done)
        #expect(!FileManager.default.fileExists(atPath: mod.path))
    }

    @Test func readOnlyParentIsExplained() async {
        let f = Fixture()
        let parent = f.dir("Applications/Locked")
        let app = f.file("Applications/Locked/Tool.app", bytes: 10)
        chmod(parent.path, 0o555)
        let results = await run(f, [Step("Trash", .trash([app]), itemID: "a")],
                                items: [Item(id: "a", title: "Tool", paths: [app], bytes: 0, risk: .review)])
        guard case .failed(let why) = results.first?.outcome else { Issue.record("expected failure"); return }
        #expect(why != Executor.needsFullDiskAccess)
        #expect(why.contains("read-only"))
        #expect(FileManager.default.fileExists(atPath: app.path))
    }

    // MARK: Providers

    @Test func ollamaIgnoresDigestsThatLeaveTheBlobsFolder() async throws {
        let f = Fixture()
        f.file("Documents/secret.txt", bytes: 100)
        f.dir(".ollama/models/blobs/sha256-abc")
        f.file(".ollama/models/manifests/registry.ollama.ai/library/evil/latest",
               contents: #"{"layers":[{"digest":"sha256:abc/../../../../Documents/secret.txt"}]}"#)
        let env = f.env()
        let items = await AIModelsProvider().scan(env, pins: Pins())
        let item = try #require(items.first)
        #expect(!item.paths.contains { $0.path.contains("Documents") })
        let plan = await AIModelsProvider().plan([item.id], items: items, env: env)
        let paths = plan.steps.flatMap { s -> [URL] in if case .trash(let u) = s.kind { u } else { [] } }
        #expect(!paths.contains { $0.path.contains("Documents") })
    }

    @Test func databaseWithALivePidFileIsRunning() async throws {
        let f = Fixture()
        f.file("opt/homebrew/bin/brew", contents: "#!/bin/sh\n")
        f.file("opt/homebrew/var/postgresql@13/PG_VERSION", bytes: 100)
        f.file("opt/homebrew/var/postgresql@13/postmaster.pid", contents: "\(getpid())\n/data\n")
        f.file("opt/homebrew/var/mysql/host.pid", contents: "99999999\n")
        let runner = FakeRunner(["brew services list --json": FakeRunner.out("[]"),
                                 "brew list --formula": FakeRunner.out("")], tools: ["brew"])
        let env = f.env(runner: runner)
        let items = await DatabasesProvider().scan(env, pins: Pins())
        let pg = try #require(items.first { $0.id == "db.postgresql@13" })
        let mysql = try #require(items.first { $0.id == "db.mysql" })
        #expect(pg.badges.contains(.running))
        #expect(!mysql.badges.contains(.running))
        let plan = await DatabasesProvider().plan([pg.id], items: items, env: env)
        #expect(plan.steps.isEmpty)
        #expect(plan.refusals.count == 1)
    }

    @Test func loginItemsOnAnUnmountedVolumeAreNotLeftovers() async throws {
        let f = Fixture()
        let plist: [String: Any] = ["Label": "com.example.external", "Program": "/Volumes/ballast-no-such-disk/bin/tool"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        f.file("Library/LaunchAgents/com.example.external.plist", contents: String(decoding: data, as: UTF8.self))
        #expect(await LoginItemsProvider().scan(f.env(), pins: Pins()).isEmpty)
    }

    @Test func rvmDownloadsCleansOnlyDownloads() async throws {
        let f = Fixture()
        f.file(".rvm/rubies/ruby-3.2.0/bin/ruby", bytes: 10)
        f.file(".rvm/src/ruby-3.2.0/configure", bytes: 10)
        let env = f.env()
        let items = await RubyProvider().scan(env, pins: Pins())
        let plan = await RubyProvider().plan(["ruby.rvm.downloads"], items: items, env: env)
        guard case .shell(let script) = try #require(plan.steps.first).kind else { Issue.record("not shell"); return }
        #expect(script.contains("rvm cleanup archives"))
        #expect(script.contains("rvm cleanup sources"))
        #expect(!script.contains("cleanup all"))
    }

    @Test func worktreeWithARelativeGitdirFindsItsRepo() {
        let f = Fixture()
        f.dir("Projects/repo/.git/worktrees/wt")
        let wt = f.dir("Projects/wt")
        f.file("Projects/wt/.git", contents: "gitdir: ../repo/.git/worktrees/wt\n")
        #expect(ProjectLeftoversProvider().mainRepo(of: wt) == f.url("Projects/repo").path)
    }

    @Test func appleAppsFromTheAppStoreCanBeRemoved() async throws {
        let f = Fixture()
        f.file("Applications/Pages.app/Contents/Info.plist", contents: plist("com.apple.iWork.Pages"))
        f.dir("Applications/Pages.app/Contents/_MASReceipt")
        let env = f.env()
        let items = await AppsProvider().scan(env, pins: Pins())
        let plan = await AppsProvider().plan(items.map(\.id), items: items, env: env)
        #expect(plan.refusals.isEmpty)
        #expect(plan.steps.first?.kind == .trash([f.url("Applications/Pages.app")]))
    }

    // MARK: mise

    func mise() -> Fixture {
        let f = Fixture()
        let installs = ".local/share/mise/installs"
        for (tool, v) in [("node", "22.1.0"), ("node", "24.15.0"), ("ruby", "4.0.5"), ("python", "3.12.4")] {
            f.file("\(installs)/\(tool)/\(v)/bin/x", bytes: 10_000)
        }
        f.link("\(installs)/node/24", to: "\(installs)/node/24.15.0")
        f.link("\(installs)/node/latest", to: "\(installs)/node/24.15.0")
        f.file(".config/mise/config.toml", contents: "[tools]\nnode = \"24\"\nruby = \"latest\"\n")
        f.file("Projects/app/mise.toml", contents: "[env]\nX = \"1\"\n\n[tools]\nnode = \"22\"\npython = [\"3.12\", \"3.11\"]\n")
        return f
    }

    @Test func miseNodeVersions() async throws {
        let f = mise()
        let env = f.env()
        let pins = scanPins(roots: [f.url("Projects")])
        let items = await NodeProvider().scan(env, pins: pins)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(Set(byID.keys) == ["node.mise.22.1.0", "node.mise.24.15.0"])
        #expect(byID["node.mise.24.15.0"]?.badges.contains(.isDefault) == true)
        #expect(byID["node.mise.22.1.0"]?.badges.contains(.pinned(by: ["app"])) == true)
        let plan = await NodeProvider().plan(["node.mise.22.1.0"], items: items, env: env)
        #expect(plan.steps.first?.kind == .command(argv: ["mise", "uninstall", "node@22.1.0"]))
    }

    @Test func miseRubyAndPython() async throws {
        let f = mise()
        let env = f.env()
        let pins = scanPins(roots: [f.url("Projects")])
        let ruby = try #require(await RubyProvider().scan(env, pins: pins).first { $0.id == "ruby.mise.4.0.5" })
        #expect(ruby.badges.contains(.isDefault))
        let rubyPlan = await RubyProvider().plan([ruby.id], items: [ruby], env: env)
        #expect(rubyPlan.steps.first?.kind == .command(argv: ["mise", "uninstall", "ruby@4.0.5"]))
        let python = try #require(await PythonProvider().scan(env, pins: pins).first { $0.id == "python.mise.3.12.4" })
        #expect(python.badges.contains(.pinned(by: ["app"])))
        let pyPlan = await PythonProvider().plan([python.id], items: [python], env: env)
        #expect(pyPlan.steps.first?.kind == .command(argv: ["mise", "uninstall", "python@3.12.4"]))
    }

    // MARK: Update check

    @Test func releaseLinksMustPointAtGitHub() {
        #expect(releaseLink("https://github.com/linearza/ballast/releases/tag/v0.2.0") != nil)
        #expect(releaseLink("https://evil.example/ballast") == nil)
        #expect(releaseLink("http://github.com/linearza/ballast") == nil)
        #expect(releaseLink("https://github.com.evil.example/x") == nil)
    }
}

@Suite struct RunningAppTests {
    @Test func matchesTheRunningCopyOnly() {
        let xcode = URL(filePath: "/Applications/Xcode.app")
        let beta = URL(filePath: "/Applications/Xcode-beta.app")
        #expect(isAppRunning(xcode, running: [URL(filePath: "/Applications/Xcode.app/"), nil]))
        #expect(!isAppRunning(beta, running: [xcode]))
        #expect(!isAppRunning(xcode, running: []))
    }
}
