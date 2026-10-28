import Foundation
import Testing
@testable import BallastCore

/// Items left open after 0.3.0.
@Suite struct OpenItemsTests {
    func plist(_ dict: [String: Any]) -> String {
        String(decoding: try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0), as: UTF8.self)
    }

    // MARK: pnpm

    @Test func pnpmCountsOnlyPackagesNoProjectUses() async throws {
        let f = Fixture()
        let used = f.file("Library/pnpm/store/v3/files/aa/used", bytes: 40_000)
        let unused = f.file("Library/pnpm/store/v3/files/bb/unused", bytes: 80_000)
        f.dir("Projects/app/node_modules/.pnpm")
        f.hardlink("Projects/app/node_modules/.pnpm/used", to: "Library/pnpm/store/v3/files/aa/used")
        let items = await PackageCachesProvider().scan(f.env(runner: FakeRunner(tools: ["pnpm"])), pins: Pins())
        let pnpm = try #require(items.first { $0.id == "cache.pnpm" })
        #expect(pnpm.bytes == (await measure([unused])).bytes)
        #expect(pnpm.bytes < (await measure([used, unused])).bytes)
    }

    @Test func pnpmStoreWithoutPnpmIsTrashedWhole() async throws {
        let f = Fixture()
        f.file("Library/pnpm/store/v3/files/aa/used", bytes: 40_000)
        f.file("Projects/app/node_modules/.pnpm/x", bytes: 10)
        f.hardlink("Projects/app/node_modules/.pnpm/used", to: "Library/pnpm/store/v3/files/aa/used")
        let items = await PackageCachesProvider().scan(f.env(), pins: Pins())
        let pnpm = try #require(items.first { $0.id == "cache.pnpm" })
        #expect(pnpm.bytes == (await measure([f.url("Library/pnpm/store")])).bytes)
    }

    // MARK: Large files

    @Test func largeFilesInICloudNeedAcknowledging() async throws {
        let f = Fixture()
        let synced = f.file("Desktop/movie.mov", bytes: 2_000)
        f.file("Downloads/local.iso", bytes: 2_000)
        let p = LargeFilesProvider(minBytes: 1_000, inICloud: { $0.lastPathComponent == synced.lastPathComponent })
        let env = f.env()
        let items = await p.scan(env, pins: Pins())
        let mov = try #require(items.first { $0.title == "movie.mov" })
        #expect(mov.badges.contains(.inICloud))
        #expect(items.first { $0.title == "local.iso" }?.badges.contains(.inICloud) == false)
        let plan = await p.plan(items.map(\.id), items: items, env: env)
        #expect(plan.dangers.count == 1)
        #expect(plan.dangers.first?.contains("every device") == true)
    }

    // MARK: Login items

    @Test func loginItemsWithTheSameLabelGetTheirOwnIDs() async {
        let f = Fixture()
        let agent: [String: Any] = ["Label": "com.example.agent", "Program": "/nonexistent/ballast/agent"]
        f.file("Library/LaunchAgents/com.example.agent.plist", contents: plist(agent))
        f.file("Library/LaunchAgents/com.example.agent.old.plist", contents: plist(agent))
        let items = await LoginItemsProvider().scan(f.env(), pins: Pins())
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test func appLaunchAgentsAreStoppedBeforeTheyGo() async throws {
        let f = Fixture()
        f.file("Applications/Sync.app/Contents/Info.plist", contents: plist(["CFBundleIdentifier": "com.example.sync"]))
        let agent = f.file("Library/LaunchAgents/com.example.sync.helper.plist",
                           contents: plist(["Label": "com.example.sync.helper", "Program": "/Applications/Sync.app/helper"]))
        let prefs = f.file("Library/Preferences/com.example.sync.plist", contents: "x")
        let env = f.env()
        let items = await AppsProvider().scan(env, pins: Pins())
        let plan = await AppsProvider().plan(items.map(\.id), items: items, env: env)
        let kinds = plan.steps.map(\.kind)
        #expect(kinds.contains(.unloadLoginItem(label: "com.example.sync.helper", plist: agent)))
        let trashed = kinds.flatMap { k -> [URL] in if case .trash(let u) = k { u } else { [] } }
        #expect(trashed.contains(prefs))
        #expect(!trashed.contains(agent))
    }

    // MARK: Project leftovers

    @Test func tinyBuildFoldersAreLeftOut() async {
        let f = Fixture()
        f.file("Projects/web/package.json", contents: "{}")
        f.file("Projects/web/dist/index.js", bytes: 100)
        f.file("Projects/site/package.json", contents: "{}")
        f.file("Projects/site/dist/bundle.js", bytes: 2_000_000)
        let items = await ProjectLeftoversProvider(minBytes: 1_000_000).scan(f.env(), pins: Pins())
        #expect(!items.contains { $0.id == "project.build.\(f.url("Projects/web/dist").path)" })
        #expect(items.contains { $0.id == "project.build.\(f.url("Projects/site/dist").path)" })
    }

    // MARK: Python

    @Test func removingAPythonNamesTheEnvironmentsBuiltOnIt() async throws {
        let f = Fixture()
        let py = f.file(".pyenv/versions/3.11.4/bin/python3", bytes: 10).deletingLastPathComponent()
        f.file(".pyenv/versions/3.12.1/bin/python3", bytes: 10)
        f.file(".local/pipx/venvs/black/pyvenv.cfg", contents: "home = \(py.path)\nversion = 3.11.4\n")
        f.file("Library/Caches/pypoetry/virtualenvs/app-x1y2-py3.11/pyvenv.cfg", contents: "home = \(py.path)\n")
        f.file("Library/Caches/pypoetry/virtualenvs/svc-z9-py3.12/pyvenv.cfg",
               contents: "home = \(f.url(".pyenv/versions/3.12.1/bin").path)\n")
        let env = f.env()
        let items = await PythonProvider().scan(env, pins: Pins())
        let plan = await PythonProvider().plan(["python.pyenv.3.11.4"], items: items, env: env)
        let danger = try #require(plan.dangers.first { $0.contains("Python 3.11.4") })
        #expect(danger.contains("black"))
        #expect(danger.contains("app-x1y2-py3.11"))
        #expect(!danger.contains("svc"))
        // Removing the environments along with it is fine.
        let both = await PythonProvider().plan(["python.pyenv.3.11.4", "python.pipx.black", "python.poetry.app-x1y2-py3.11"],
                                               items: items, env: env)
        #expect(both.dangers.isEmpty)
    }

    // MARK: RVM

    @Test func implodeNamesTheVersionsInUse() async throws {
        let f = Fixture()
        for v in ["3.3.0", "4.0.5"] { f.file(".rvm/rubies/ruby-\(v)/bin/ruby", bytes: 10) }
        f.file(".rvm/config/alias", contents: "default=ruby-4.0.5\n")
        f.file("Projects/shop/.ruby-version", contents: "3.3.0\n")
        let env = f.env()
        let items = await RubyProvider().scan(env, pins: scanPins(roots: [f.url("Projects")]))
        let plan = await RubyProvider().plan([RubyProvider.implode], items: items, env: env)
        #expect(plan.dangers.contains { $0.contains("shop") })
        #expect(plan.dangers.contains { $0.contains("default") })
    }
}
