import Foundation
import Testing
@testable import BallastCore

/// Guards that keep a less technical user from removing something they'll regret.
@Suite struct SafetyTests {
    func item(_ id: String, risk: Risk = .regenerable, badges: Set<Badge> = []) -> Item {
        Item(id: id, title: id.uppercased(), paths: [], bytes: 10, risk: risk, badges: badges)
    }

    func plan(_ items: [Item], kind: StepKind = .trash([])) -> Plan {
        Plan(steps: items.map { Step("Remove", kind, itemID: $0.id) })
    }

    // MARK: How careful the confirmation is

    @Test func regenerableItemsAreRoutine() {
        let a = item("a")
        #expect(caution(of: plan([a]), items: [a]) == .routine)
        #expect(dangerNotes(plan([a]), items: [a]).isEmpty)
    }

    @Test func reviewItemsOrWarningsAskForCare() {
        let a = item("a", risk: .review)
        #expect(caution(of: plan([a]), items: [a]) == .careful)
        let b = item("b")
        var p = plan([b])
        p.warnings = ["Heads up"]
        #expect(caution(of: p, items: [b]) == .careful)
    }

    @Test func yourDataNeedsAcknowledging() {
        let a = item("a", risk: .yourData)
        #expect(caution(of: plan([a]), items: [a]) == .dangerous)
        #expect(dangerNotes(plan([a]), items: [a]).contains { $0.contains("A") })
    }

    @Test func providerDangersNeedAcknowledging() {
        let a = item("a")
        var p = plan([a])
        p.dangers = ["This removes everything"]
        #expect(caution(of: p, items: [a]) == .dangerous)
        #expect(dangerNotes(p, items: [a]) == ["This removes everything"])
    }

    @Test func stepsSayWhetherTheyCanBeUndone() {
        #expect(StepKind.trash([]).undo == .fromTrash)
        #expect(StepKind.unloadLoginItem(label: "x", plist: URL(filePath: "/x")).undo == .fromTrash)
        #expect(StepKind.command(argv: ["x"]).undo == .never)
        #expect(StepKind.shell("x").undo == .never)
        #expect(StepKind.truncate(URL(filePath: "/x")).undo == .never)
        #expect(StepKind.copyToTerminal("x").undo == .yourCall)
    }

    // MARK: Providers

    @Test func inUseVersionsAreDangers() async {
        let f = Fixture()
        f.file(".rbenv/versions/3.3.0/bin/ruby", bytes: 10)
        f.file(".rbenv/version", contents: "3.3.0\n")
        let env = f.env()
        let items = await RubyProvider().scan(env, pins: Pins())
        let p = await RubyProvider().plan(items.map(\.id), items: items, env: env)
        #expect(p.dangers.contains { $0.contains("default") })
        #expect(!p.warnings.contains { $0.contains("default") })
    }

    @Test func uninstallingOllamaIsADanger() async {
        let f = Fixture()
        f.file(".ollama/models/blobs/sha256-a", bytes: 10)
        let env = f.env()
        let p = await AIModelsProvider().uninstallPlan([], env: env)
        #expect(p.dangers.contains { $0.contains("every model") })
    }

    @Test func autoremoveIsAReview() async throws {
        let f = Fixture()
        f.file("opt/homebrew/bin/brew", contents: "#!/bin/sh\n")
        f.file("opt/homebrew/Cellar/libfoo/1.0/lib/x", bytes: 10)
        let r = FakeRunner(["brew autoremove -n": FakeRunner.out("==> Would autoremove 1 unneeded formula:\nlibfoo\n")], tools: ["brew"])
        let items = await HomebrewProvider().scan(f.env(runner: r), pins: Pins())
        // You may use a formula yourself that came in as a dependency.
        #expect(try #require(items.first { $0.id == "brew.autoremove" }).risk == .review)
    }

    @Test func appDataGoingWithAnAppIsADanger() async {
        let f = Fixture()
        f.file("Applications/Notes Pro.app/Contents/Info.plist", contents: """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.notes</string></dict></plist>
            """)
        f.file("Library/Application Support/com.example.notes/notes.db", bytes: 100)
        let env = f.env()
        let items = await AppsProvider().scan(env, pins: Pins())
        let p = await AppsProvider().plan(items.map(\.id), items: items, env: env)
        #expect(p.dangers.contains { $0.contains("Notes Pro") && $0.contains("data") })
    }

    @Test func appWithOnlyCachesIsNoDanger() async {
        let f = Fixture()
        f.file("Applications/Tool.app/Contents/Info.plist", contents: """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.tool</string></dict></plist>
            """)
        f.file("Library/Caches/com.example.tool/x", bytes: 100)
        let env = f.env()
        let items = await AppsProvider().scan(env, pins: Pins())
        let p = await AppsProvider().plan(items.map(\.id), items: items, env: env)
        #expect(p.dangers.isEmpty)
    }

    @Test func buildFoldersTrackedByGitAreLeftAlone() async {
        let f = Fixture()
        // Some teams commit Pods or dist; those are source, not leftovers.
        let dir = f.file("Projects/app/Podfile", contents: "").deletingLastPathComponent()
        f.file("Projects/app/Pods/Lib/x.m", bytes: 100)
        f.file("Projects/app/.gitignore", contents: "build/\n")
        git(dir, "init", "-q")
        git(dir, "add", ".")
        git(dir, "commit", "-q", "-m", "first", date: "2026-01-01T10:00:00Z")
        f.file("Projects/svc/Cargo.toml", contents: "[package]\n")
        f.file("Projects/svc/target/debug/app", bytes: 100)
        let items = await ProjectLeftoversProvider(minBytes: 0).scan(f.env(runner: FakeRunner([:], passthrough: ["git"])), pins: Pins())
        #expect(!items.contains { $0.id == "project.build.\(f.url("Projects/app/Pods").path)" })
        #expect(items.contains { $0.id == "project.build.\(f.url("Projects/svc/target").path)" })
    }

    // MARK: Last line of defence

    @Test func executorNeverTrashesProtectedFolders() async {
        let f = Fixture()
        let env = f.env()
        for rel in ["", "Documents", "Desktop", "Library", "Library/Keychains", ".ssh"] { f.dir(rel) }
        f.file(".ssh/id_ed25519", contents: "key")
        f.file("Library/Keychains/login.keychain-db", bytes: 10)
        let targets = [f.root, f.url("Documents"), f.url("Desktop"), f.url("Library"), f.url(".ssh/id_ed25519"),
                       f.url("Library/Keychains/login.keychain-db"), f.root.deletingLastPathComponent()]
        let executor = Executor(env: env, logURL: f.url("state/actions.log"))
        for target in targets {
            let outcome = await executor.perform(.trash([target]))
            guard case .failed(let why) = outcome else { Issue.record("trashed \(target.path)"); continue }
            #expect(why == Executor.protectedPath)
            #expect(FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func executorStillTrashesOrdinaryFolders() async {
        let f = Fixture()
        let cache = f.file("Library/Caches/com.example/x", bytes: 10).deletingLastPathComponent()
        let outcome = await Executor(env: f.env(), logURL: f.url("state/actions.log")).perform(.trash([cache]))
        #expect(outcome == .done)
    }

    // MARK: Safe to reclaim

    @Test func safeItemsAcrossConcerns() {
        let now = Date()
        let a = ConcernReport(id: "a", title: "A", section: .caches, symbol: "x",
                              items: [item("a1"), item("a2", risk: .review), item("a3", badges: [.isDefault])], scannedAt: now)
        let b = ConcernReport(id: "b", title: "B", section: .caches, symbol: "x", items: [item("b1", risk: .yourData)], scannedAt: now)
        let c = ConcernReport(id: "c", title: "C", section: .caches, symbol: "x", items: [item("c1"), item("c2")], scannedAt: now)
        let groups = safeGroups([a, b, c])
        #expect(groups.map(\.report.id) == ["c", "a"])
        #expect(groups.first?.items.map(\.id).sorted() == ["c1", "c2"])
        #expect(groups.last?.items.map(\.id) == ["a1"])
    }
}
