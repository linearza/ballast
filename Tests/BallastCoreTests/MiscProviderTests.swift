import Foundation
import Testing
@testable import BallastCore

@Suite struct MiscProviderTests {
    @Test func packageCacheUsesToolWhenPresent() async throws {
        let f = Fixture()
        f.file(".npm/_cacache/index", bytes: 5000)
        let p = PackageCachesProvider()
        for (tools, expectCommand) in [(Set(["npm"]), true), ([], false)] {
            let env = f.env(runner: FakeRunner(tools: tools))
            let items = await p.scan(env, pins: Pins())
            let npm = try #require(items.first { $0.id == "cache.npm" })
            #expect(npm.risk == .regenerable)
            let plan = await p.plan([npm.id], items: items, env: env)
            let kind = try #require(plan.steps.first?.kind)
            if expectCommand { #expect(kind == .command(argv: ["npm", "cache", "clean", "--force"])) }
            else { #expect(kind == .trash([f.url(".npm/_cacache")])) }
        }
    }

    @Test func appCacheNamesKnown() async throws {
        let f = Fixture()
        f.file("Library/Caches/ms-playwright/chromium/bin", bytes: 50_000)
        f.file("Library/Caches/tiny/x", bytes: 10)
        let items = await AppCachesProvider(minBytes: 20_000).scan(f.env(), pins: Pins())
        #expect(items.map(\.title) == ["Playwright browsers"])
        #expect(items.first?.risk == .regenerable)
    }

    @Test func appCacheSkipsApple() async throws {
        let f = Fixture()
        f.file("Library/Caches/com.apple.Safari/x", bytes: 50_000)
        f.file("Library/Caches/Yarn/x", bytes: 50_000)
        f.file("Library/Caches/SomeTool/x", bytes: 50_000)
        let items = await AppCachesProvider(minBytes: 20_000).scan(f.env(), pins: Pins())
        #expect(items.map(\.title) == ["SomeTool"])
    }

    func ollama(_ f: Fixture) {
        func manifest(_ name: String, _ tag: String, _ digests: [String]) {
            let layers = digests.map { #"{"digest":"sha256:\#($0)","size":1}"# }.joined(separator: ",")
            f.file(".ollama/models/manifests/registry.ollama.ai/library/\(name)/\(tag)",
                   contents: #"{"config":{"digest":"sha256:cfg\#(name)","size":1},"layers":[\#(layers)]}"#)
            f.file(".ollama/models/blobs/sha256-cfg\(name)", bytes: 100)
        }
        f.file(".ollama/models/blobs/sha256-shared", bytes: 100_000)
        f.file(".ollama/models/blobs/sha256-own1", bytes: 200_000)
        f.file(".ollama/models/blobs/sha256-own2", bytes: 300_000)
        manifest("llama", "8b", ["shared", "own1"])
        manifest("qwen", "7b", ["shared", "own2"])
    }

    @Test func ollamaSizesFromManifests() async throws {
        let f = Fixture()
        ollama(f)
        let env = f.env()
        let p = AIModelsProvider()
        let items = await p.scan(env, pins: Pins())
        let llama = try #require(items.first { $0.id == "ai.ollama.llama:8b" })
        let qwen = try #require(items.first { $0.id == "ai.ollama.qwen:7b" })
        #expect(llama.bytes >= 300_000 && llama.bytes < 320_000)
        #expect(qwen.bytes >= 400_000 && qwen.bytes < 420_000)
        #expect(llama.risk == .review)
        let plan = await p.plan([llama.id], items: items, env: env)
        guard case .trash(let urls) = try #require(plan.steps.first?.kind) else { Issue.record("expected trash"); return }
        let names = Set(urls.map(\.lastPathComponent))
        #expect(names.contains("8b"))
        #expect(names.contains("sha256-own1"))
        #expect(names.contains("sha256-cfgllama"))
        #expect(!names.contains("sha256-shared"))
    }

    @Test func ollamaUsesRmWhenServerUp() async throws {
        let f = Fixture()
        ollama(f)
        let env = f.env(runner: FakeRunner(["ollama list": FakeRunner.ok], tools: ["ollama"]))
        let p = AIModelsProvider()
        let items = await p.scan(env, pins: Pins())
        let plan = await p.plan(["ai.ollama.qwen:7b"], items: items, env: env)
        #expect(plan.steps.first?.kind == .command(argv: ["ollama", "rm", "qwen:7b"]))
    }

    @Test func largeFilesNeedsUserStart() {
        #expect(Providers.all.filter(\.needsUserStart).map(\.id) == ["largeFiles"])
    }

    @Test func largeFilesFindsBigFiles() async throws {
        let f = Fixture()
        f.file("Downloads/movie.mkv", bytes: 50_000)
        f.file("Documents/small.txt", bytes: 10)
        let items = await LargeFilesProvider(minBytes: 20_000).scan(f.env(), pins: Pins())
        #expect(items.map(\.title) == ["movie.mkv"])
        #expect(items.first?.risk == .yourData)
    }

    @Test func appUninstallFindsLeftovers() async throws {
        let f = Fixture()
        f.file("Applications/X.app/Contents/Info.plist", contents: """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.x</string></dict></plist>
        """)
        f.file("Library/Caches/com.example.x/data", bytes: 100)
        f.file("Library/Preferences/com.example.x.plist", bytes: 10)
        f.file("Library/Caches/com.example.other/data", bytes: 100)
        let env = f.env()
        let p = AppsProvider()
        let items = await p.scan(env, pins: Pins())
        let app = try #require(items.first { $0.title == "X" })
        let plan = await p.plan([app.id], items: items, env: env)
        let paths = plan.steps.flatMap { step -> [URL] in if case .trash(let u) = step.kind { u } else { [] } }.map(\.path)
        #expect(paths.contains(f.url("Applications/X.app").path))
        #expect(paths.contains(f.url("Library/Caches/com.example.x").path))
        #expect(paths.contains(f.url("Library/Preferences/com.example.x.plist").path))
        #expect(!paths.contains(f.url("Library/Caches/com.example.other").path))
    }

    @Test func appleAppsHaveNoPlan() async throws {
        let f = Fixture()
        f.file("Applications/Safari.app/Contents/Info.plist", contents: """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.apple.Safari</string></dict></plist>
        """)
        let env = f.env()
        let items = await AppsProvider().scan(env, pins: Pins())
        let plan = await AppsProvider().plan(items.map(\.id), items: items, env: env)
        #expect(plan.steps.isEmpty)
        #expect(plan.refusals.count == 1)
    }

    @Test func otherDevDataHints() async throws {
        let f = Fixture()
        f.file("Library/Application Support/Claude/vm_bundles/x", bytes: 100)
        let items = await OtherDevDataProvider().scan(f.env(), pins: Pins())
        #expect(items.first?.detail == "Prefer clearing from inside Claude")
        #expect(items.first?.risk == .review)
    }
}
