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

@Suite struct VirtualMachinesTests {
    @Test func containerRuntimesAndVMs() async throws {
        let f = Fixture()
        f.file(".colima/default/colima.yaml", bytes: 10)
        f.file(".colima/_lima/colima/diffdisk", bytes: 1000)
        f.file(".lima/dev/diffdisk", bytes: 1000)
        f.file(".lima/busy/diffdisk", bytes: 1000)
        f.file(".lima/busy/ha.pid", contents: "\(getpid())\n")
        f.file(".minikube/machines/minikube/disk.rawdisk", bytes: 1000)
        f.file(".minikube/profiles/minikube/config.json", contents: "{}")
        f.file(".local/share/containers/podman/machine/applehv/podman-machine-default-arm64.raw", bytes: 1000)
        f.file("Parallels/Windows 11.pvm/disk.hdd", bytes: 1000)
        f.file("Virtual Machines.localized/Ubuntu.vmwarevm/disk.vmdk", bytes: 1000)
        let env = f.env(runner: FakeRunner(tools: ["colima", "limactl", "minikube", "podman"]))
        let p = VirtualMachinesProvider()
        let items = await p.scan(env, pins: Pins())
        let m = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(Set(m.keys) == ["vm.colima.default", "vm.lima.dev", "vm.lima.busy", "vm.minikube.minikube", "vm.podman",
                                "vm.parallels.Windows 11.pvm", "vm.vmware.Ubuntu.vmwarevm"])
        #expect(m["vm.colima.default"]?.paths.contains(f.url(".colima/_lima/colima")) == true)
        #expect(m["vm.lima.busy"]?.badges.contains(.running) == true)
        #expect(m["vm.parallels.Windows 11.pvm"]?.risk == .yourData)
        func kind(_ id: String) async -> StepKind? { await p.plan([id], items: items, env: env).steps.first?.kind }
        #expect(await kind("vm.colima.default") == .command(argv: ["colima", "delete", "--force", "--profile", "default"]))
        #expect(await kind("vm.lima.dev") == .command(argv: ["limactl", "delete", "--force", "dev"]))
        #expect(await kind("vm.minikube.minikube") == .command(argv: ["minikube", "delete", "--profile", "minikube"]))
        let busy = await p.plan(["vm.lima.busy"], items: items, env: env)
        #expect(busy.steps.isEmpty)
        #expect(busy.refusals.first?.reason.contains("limactl stop busy") == true)
    }
}

@Suite struct XcodeAndAndroidTests {
    @Test func moreXcodeFolders() async throws {
        let f = Fixture()
        for rel in ["Library/Developer/Xcode/watchOS DeviceSupport", "Library/Developer/Xcode/tvOS DeviceSupport",
                    "Library/Developer/Xcode/visionOS DeviceSupport", "Library/Logs/CoreSimulator",
                    "Library/Developer/Xcode/DocumentationCache"] { f.file("\(rel)/x", bytes: 10) }
        let ids = Set(await XcodeProvider().scan(f.env(), pins: Pins()).map(\.id))
        #expect(ids.isSuperset(of: ["xcode.watchsupport", "xcode.tvsupport", "xcode.visionsupport", "xcode.simlogs", "xcode.docs"]))
    }

    @Test func androidImagesNdksAndEmulators() async throws {
        let f = Fixture()
        f.file("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a/system.img", bytes: 100)
        f.file("Library/Android/sdk/ndk/26.1.10909125/source.properties", bytes: 10)
        f.file(".android/avd/Pixel_8.avd/userdata.img", bytes: 100)
        f.file(".android/avd/Pixel_8.ini", contents: "path=x\n")
        let env = f.env(runner: FakeRunner(tools: ["sdkmanager", "avdmanager"]))
        let p = AndroidProvider()
        let items = await p.scan(env, pins: Pins())
        let m = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(Set(m.keys) == ["android.image.android-34;google_apis;arm64-v8a", "android.ndk.26.1.10909125", "android.avd.Pixel_8"])
        #expect(m["android.avd.Pixel_8"]?.paths == [f.url(".android/avd/Pixel_8.avd"), f.url(".android/avd/Pixel_8.ini")])
        func kind(_ id: String) async -> StepKind? { await p.plan([id], items: items, env: env).steps.first?.kind }
        #expect(await kind("android.image.android-34;google_apis;arm64-v8a")
                == .command(argv: ["sdkmanager", "--uninstall", "system-images;android-34;google_apis;arm64-v8a"]))
        #expect(await kind("android.ndk.26.1.10909125") == .command(argv: ["sdkmanager", "--uninstall", "ndk;26.1.10909125"]))
        #expect(await kind("android.avd.Pixel_8") == .command(argv: ["avdmanager", "delete", "avd", "-n", "Pixel_8"]))
    }
}
