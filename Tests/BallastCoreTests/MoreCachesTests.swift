import Foundation
import Testing
@testable import BallastCore

/// Caches, project build output, containers and editors added in 0.2.0.
@Suite struct MoreCachesTests {
    func byID(_ items: [Item]) -> [String: Item] { Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }) }

    @Test func morePackageCaches() async throws {
        let f = Fixture()
        let rels = [".bun/install/cache", "Library/Caches/deno", ".cache/uv", "Library/Caches/pypoetry/cache",
                    "miniforge3/pkgs", ".m2/repository", ".ivy2/cache", ".sbt/boot", "Library/Caches/Coursier",
                    "Library/Caches/org.swift.swiftpm", "Library/Caches/org.carthage.CarthageKit", ".nuget/packages",
                    "Library/Caches/composer", "Library/Caches/electron", ".bundle/cache", "go/pkg/mod"]
        for rel in rels { f.file("\(rel)/x", bytes: 10) }
        let runner = FakeRunner(tools: ["uv", "go", "conda", "dotnet", "composer"])
        let env = f.env(runner: runner)
        let p = PackageCachesProvider()
        let items = await p.scan(env, pins: Pins())
        let m = byID(items)
        for key in ["bun", "deno", "uv", "poetry", "conda", "maven", "ivy", "sbt", "coursier", "swiftpm", "carthage",
                    "nuget", "composer", "electron", "bundler", "gomod"] {
            #expect(m["cache.\(key)"] != nil, "missing cache.\(key)")
        }
        func kind(_ id: String) async -> StepKind? { await p.plan([id], items: items, env: env).steps.first?.kind }
        #expect(await kind("cache.uv") == .command(argv: ["uv", "cache", "clean"]))
        #expect(await kind("cache.gomod") == .command(argv: ["go", "clean", "-modcache"]))
        #expect(await kind("cache.conda") == .command(argv: ["conda", "clean", "--all", "-y"]))
        #expect(await kind("cache.nuget") == .command(argv: ["dotnet", "nuget", "locals", "all", "--clear"]))
        #expect(await kind("cache.maven") == .trash([f.url(".m2/repository")]))
        // Poetry's virtualenvs belong to Python, so app caches leave the whole folder alone.
        #expect(PackageCachesProvider.claimedCacheNames.contains("pypoetry"))
    }
}
