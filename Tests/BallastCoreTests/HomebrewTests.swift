import Foundation
import Testing
@testable import BallastCore

@Suite struct HomebrewTests {
    static let services = """
    [{"name":"postgresql@14","status":"started","user":"me","file":"x","exit_code":null},
     {"name":"redis","status":"none","user":null,"file":"y","exit_code":null}]
    """

    func brew() -> (Fixture, FakeRunner) {
        let f = Fixture()
        f.file("opt/homebrew/bin/brew", contents: "#!/bin/sh\n")
        f.file("opt/homebrew/var/postgresql@14/PG_VERSION", bytes: 50_000)
        f.file("opt/homebrew/var/postgresql@13/PG_VERSION", bytes: 80_000)
        f.file("opt/homebrew/var/log/postgresql@14.log", bytes: 12_000_000)
        f.file("opt/homebrew/var/log/redis.log", bytes: 20_000_000)
        f.file("opt/homebrew/var/log/tiny.log", bytes: 1000)
        f.file("opt/homebrew/Cellar/libfoo/1.0/lib.dylib", bytes: 300_000)
        let runner = FakeRunner([
            "brew services list --json": FakeRunner.out(Self.services),
            "brew list --formula": FakeRunner.out("postgresql@14\nredis\nlibfoo\n"),
            "brew cleanup --prune=all -n": FakeRunner.out("Would remove: /x (10 files, 1MB)\n==> This operation would free approximately 1.2GB of disk space.\n"),
            "brew autoremove -n": FakeRunner.out("==> Would autoremove 1 unneeded formula:\nlibfoo\n"),
        ], tools: ["brew"])
        return (f, runner)
    }

    func items(_ p: any Provider, _ f: Fixture, _ r: FakeRunner) async -> [String: Item] {
        Dictionary(uniqueKeysWithValues: await p.scan(f.env(runner: r), pins: Pins()).map { ($0.id, $0) })
    }

    @Test func orphanedPostgres() async throws {
        let (f, r) = brew()
        let all = await items(DatabasesProvider(), f, r)
        let old = try #require(all["db.postgresql@13"])
        #expect(old.badges.contains(.orphaned))
        #expect(old.risk == .yourData)
        let plan = await DatabasesProvider().plan([old.id], items: Array(all.values), env: f.env(runner: r))
        #expect(plan.steps.map(\.kind) == [.trash([f.url("opt/homebrew/var/postgresql@13")])])
        #expect(plan.refusals.isEmpty)
    }

    @Test func runningPostgresRefused() async throws {
        let (f, r) = brew()
        let all = await items(DatabasesProvider(), f, r)
        let live = try #require(all["db.postgresql@14"])
        #expect(live.badges.contains(.running))
        let plan = await DatabasesProvider().plan([live.id], items: Array(all.values), env: f.env(runner: r))
        #expect(plan.steps.isEmpty)
        #expect(plan.refusals.first?.reason.contains("brew services stop postgresql@14") == true)
    }

    @Test func liveLogTruncated() async throws {
        let (f, r) = brew()
        let all = await items(HomebrewProvider(), f, r)
        let log = try #require(all["brew.log.postgresql@14.log"])
        let plan = await HomebrewProvider().plan([log.id], items: Array(all.values), env: f.env(runner: r))
        #expect(plan.steps.map(\.kind) == [.truncate(f.url("opt/homebrew/var/log/postgresql@14.log"))])
    }

    @Test func idleLogTrashed() async throws {
        let (f, r) = brew()
        let all = await items(HomebrewProvider(), f, r)
        #expect(all["brew.log.tiny.log"] == nil)
        let log = try #require(all["brew.log.redis.log"])
        let plan = await HomebrewProvider().plan([log.id], items: Array(all.values), env: f.env(runner: r))
        #expect(plan.steps.map(\.kind) == [.trash([f.url("opt/homebrew/var/log/redis.log")])])
    }

    @Test func parsesCleanupSize() async throws {
        #expect(parseBrewFreed("==> This operation would free approximately 1.2GB of disk space.") == 1_288_490_188)
        #expect(parseBrewFreed("==> This operation would free approximately 736.7MB of disk space.") == 772_485_939)
        #expect(parseBrewFreed("nothing") == nil)
        let (f, r) = brew()
        let all = await items(HomebrewProvider(), f, r)
        #expect(all["brew.cleanup"]?.bytes == 1_288_490_188)
        let plan = await HomebrewProvider().plan(["brew.cleanup"], items: Array(all.values), env: f.env(runner: r))
        #expect(plan.steps.map(\.kind) == [.command(argv: ["brew", "cleanup", "--prune=all"])])
    }

    @Test func autoremoveListsFormulae() async throws {
        let (f, r) = brew()
        let item = try #require(await items(HomebrewProvider(), f, r)["brew.autoremove"])
        #expect(item.detail?.contains("libfoo") == true)
        #expect(item.bytes >= 300_000)
    }

    @Test func danglingLoginItem() async throws {
        let f = Fixture()
        func agent(_ label: String, _ program: String) throws {
            let plist: [String: Any] = ["Label": label, "ProgramArguments": [program, "-D", "x"]]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            f.file("Library/LaunchAgents/\(label).plist", contents: String(decoding: data, as: UTF8.self))
        }
        try agent("homebrew.mxcl.postgresql@13", f.url("opt/homebrew/opt/postgresql@13/bin/postgres").path)
        try agent("com.example.fine", "/bin/ls")
        let found = await LoginItemsProvider().scan(f.env(), pins: Pins())
        #expect(found.map(\.id) == ["login.homebrew.mxcl.postgresql@13"])
        #expect(found.first?.detail?.contains("postgresql@13") == true)
        let plist = f.url("Library/LaunchAgents/homebrew.mxcl.postgresql@13.plist")
        let plan = await LoginItemsProvider().plan(found.map(\.id), items: found, env: f.env())
        #expect(plan.steps.map(\.kind) == [.unloadLoginItem(label: "homebrew.mxcl.postgresql@13", plist: plist), .trash([plist])])
    }

    @Test func noBrewNoItems() async {
        let f = Fixture()
        #expect(await HomebrewProvider().isPresent(f.env()) == false)
        #expect(await HomebrewProvider().scan(f.env(), pins: Pins()).isEmpty)
    }
}
