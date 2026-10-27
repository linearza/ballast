import Foundation
import Testing
@testable import BallastCore

/// A provider whose recheck refuses the ids it's told to.
struct StubProvider: Provider {
    var refuse: Set<String> = []
    let id = "stub"
    let title = "Stub"
    let section = Section.other
    let symbol = "circle"
    func isPresent(_ env: Environment) async -> Bool { true }
    func scan(_ env: Environment, pins: Pins) async -> [Item] { [] }
    func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan { Plan() }
    func recheck(_ item: Item, env: Environment, pins: Pins) async -> Refusal? {
        refuse.contains(item.id) ? Refusal(itemID: item.id, reason: "Now in use") : nil
    }
}

@Suite struct ExecuteTests {
    func item(_ id: String, _ paths: [URL] = []) -> Item { Item(id: id, title: id, paths: paths, bytes: 0, risk: .regenerable) }

    func run(_ f: Fixture, _ steps: [Step], runner: FakeRunner = FakeRunner(), provider: StubProvider = StubProvider(),
             items: [Item] = []) async -> [StepResult] {
        await Executor(env: f.env(runner: runner), logURL: f.url("state/actions.log"))
            .run(Plan(steps: steps), provider: provider, items: items, pins: Pins()) { _ in }
    }

    func trashed(_ f: Fixture) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: f.url(".Trash").path)) ?? [])
    }

    @Test func trashesFixtureFile() async {
        let f = Fixture()
        let u = f.file("cache/a.bin", bytes: 100)
        let results = await run(f, [Step("Trash", .trash([u]), itemID: "a")], items: [item("a", [u])])
        #expect(!FileManager.default.fileExists(atPath: u.path))
        #expect(trashed(f).contains { $0.hasSuffix("a.bin") })
        guard case .done = results.first?.outcome else { Issue.record("expected done"); return }
    }

    @Test func truncatesInPlace() async throws {
        let f = Fixture()
        let u = f.file("logs/x.log", bytes: 5000)
        _ = await run(f, [Step("Empty", .truncate(u))])
        let size = try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int
        #expect(size == 0)
    }

    @Test func recheckRefusalSkips() async {
        let f = Fixture()
        let u = f.file("keep/me", bytes: 10)
        let v = f.file("go/me", bytes: 10)
        let results = await run(f, [Step("A", .trash([u]), itemID: "a"), Step("B", .trash([v]), itemID: "b")],
                                provider: StubProvider(refuse: ["a"]), items: [item("a", [u]), item("b", [v])])
        guard case .skipped(let why) = results[0].outcome else { Issue.record("expected skipped"); return }
        #expect(why == "Now in use")
        #expect(FileManager.default.fileExists(atPath: u.path))
        #expect(!FileManager.default.fileExists(atPath: v.path))
    }

    @Test func failedCommandReportsStderr() async {
        let f = Fixture()
        let runner = FakeRunner(["brew cleanup": CommandResult(status: 1, stderr: "warming up\nError: locked")])
        let results = await run(f, [Step("Clean", .command(argv: ["brew", "cleanup"]))], runner: runner)
        guard case .failed(let why) = results.first?.outcome else { Issue.record("expected failed"); return }
        #expect(why == "Error: locked")
    }

    @Test func copyToTerminalNeverRuns() async {
        let f = Fixture()
        let runner = FakeRunner()
        let results = await run(f, [Step("Sudo", .copyToTerminal("sudo rm -rf /x"))], runner: runner)
        #expect(runner.calls.isEmpty)
        guard case .shown = results.first?.outcome else { Issue.record("expected shown"); return }
    }

    @Test func quotedPathsSurvive() async {
        let f = Fixture()
        let u = f.file("Application Support/it's/data", bytes: 10).deletingLastPathComponent()
        let results = await run(f, [Step("Trash", .trash([u]))])
        #expect(!FileManager.default.fileExists(atPath: u.path))
        guard case .done = results.first?.outcome else { Issue.record("expected done"); return }
    }

    @Test func unloadsLoginItemThenTrashesPlist() async {
        let f = Fixture()
        let plist = f.file("Library/LaunchAgents/com.x.agent.plist", contents: "<plist/>")
        let runner = FakeRunner(["launchctl bootout gui/\(getuid())/com.x.agent": CommandResult(status: 3, stderr: "Boot-out failed: 3: No such process")])
        let results = await run(f, [Step("Unload", .unloadLoginItem(label: "com.x.agent", plist: plist))], runner: runner)
        #expect(runner.calls == ["launchctl bootout gui/\(getuid())/com.x.agent"])
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        guard case .done = results.first?.outcome else { Issue.record("expected done"); return }
    }

    @Test func logsEachStep() async throws {
        let f = Fixture()
        let u = f.file("a", bytes: 10)
        let results = await run(f, [Step("Trash", .trash([u])), Step("Copy", .copyToTerminal("sudo x"))])
        let log = try String(contentsOf: f.url("state/actions.log"), encoding: .utf8)
        #expect(log.split(separator: "\n").count == results.count)
        #expect(log.contains("\tdone\tTrash\t"))
    }
}
