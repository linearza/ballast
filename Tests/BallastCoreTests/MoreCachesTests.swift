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

    // MARK: Project build output

    @Test func buildOutputInIdleProjects() async throws {
        let f = Fixture()
        let old = Date().addingTimeInterval(-200 * 86_400)
        f.file("Projects/rs/Cargo.toml", contents: "[package]\n", modified: old)
        f.file("Projects/rs/target/debug/app", bytes: 100)
        f.file("Projects/py/pyproject.toml", contents: "", modified: old)
        f.file("Projects/py/.venv/pyvenv.cfg", contents: "home = /usr\n")
        f.file("Projects/py/venv/notes.txt", bytes: 10)
        f.file("Projects/web/package.json", contents: "{}", modified: old)
        f.file("Projects/web/.next/cache/x", bytes: 100)
        f.file("Projects/web/dist/app.js", bytes: 100)
        f.file("Projects/ios/Podfile", contents: "", modified: old)
        f.file("Projects/ios/Pods/x", bytes: 100)
        f.file("Projects/ex/mix.exs", contents: "", modified: old)
        f.file("Projects/ex/_build/x", bytes: 100)
        f.file("Projects/ex/deps/x", bytes: 100)
        f.file("Projects/notes/target/x", bytes: 100)
        let items = await ProjectLeftoversProvider().scan(f.env(), pins: Pins())
        let m = byID(items)
        let id = { (rel: String) in "project.build.\(f.url(rel).path)" }
        #expect(Set(m.keys) == Set(["Projects/rs/target", "Projects/py/.venv", "Projects/web/.next", "Projects/web/dist",
                                    "Projects/ios/Pods", "Projects/ex/_build", "Projects/ex/deps"].map(id)))
        #expect(m[id("Projects/rs/target")]?.risk == .regenerable)
        #expect(m[id("Projects/rs/target")]?.title == "rs target")
        // A package's dist folder may be what it publishes, so it's always a review.
        #expect(m[id("Projects/web/dist")]?.risk == .review)
    }
}
