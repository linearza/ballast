import Foundation
import Testing
@testable import BallastCore

@Suite struct DockerXcodeTests {
    func docker() -> Fixture {
        let f = Fixture()
        f.file("Applications/Docker.app/Contents/MacOS/uninstall", bytes: 100_000)
        f.unreadable("Library/Containers/com.docker.docker")
        f.dir("Library/Group Containers/group.com.docker")
        f.file(".docker/config.json", bytes: 2000)
        f.link("usr/local/bin/docker", to: f.url("Applications/Docker.app/Contents/Resources/bin/docker").path)
        f.link("usr/local/bin/kubectl", to: f.url("Applications/Docker.app/Contents/Resources/bin/kubectl").path)
        f.link("usr/local/bin/other", to: "/bin/ls")
        f.file("Library/PrivilegedHelperTools/com.docker.vmnetd", bytes: 100)
        f.file("Library/LaunchDaemons/com.docker.vmnetd.plist", bytes: 100)
        return f
    }

    @Test func dockerDataLockedWhenUnreadable() async throws {
        let f = docker()
        let items = await DockerProvider().scan(f.env(), pins: Pins())
        let data = try #require(items.first { $0.id == "docker.data" })
        #expect(data.badges.contains(.locked))
        #expect(data.sizeIsPartial)
        #expect(data.bytes == 0)
        let measured = await measureProtected(data)
        #expect(measured.badges.contains(.locked))
    }

    @Test func protectedItemUnlocksWhenReadable() async throws {
        let f = Fixture()
        f.file("Library/Containers/com.docker.docker/Data/disk.raw", bytes: 50_000)
        f.file("Applications/Docker.app/Contents/Info.plist", bytes: 10)
        let data = try #require(await DockerProvider().scan(f.env(), pins: Pins()).first { $0.id == "docker.data" })
        let measured = await measureProtected(data)
        #expect(!measured.badges.contains(.locked))
        #expect(!measured.sizeIsPartial)
        #expect(measured.bytes >= 50_000)
    }

    @Test func dockerLinksFound() async throws {
        let f = docker()
        let links = try #require(await DockerProvider().scan(f.env(), pins: Pins()).first { $0.id == "docker.links" })
        #expect(links.paths.map(\.lastPathComponent).sorted() == ["docker", "kubectl"])
    }

    @Test func dockerUninstallOrder() async throws {
        let f = docker()
        let items = await DockerProvider().scan(f.env(), pins: Pins())
        let action = try #require(DockerProvider().extraActions(items).first)
        #expect(action.title == "Uninstall Docker completely")
        let plan = await DockerProvider().plan([action.id], items: items, env: f.env())
        let kinds = plan.steps.map(\.kind)
        #expect(kinds.first == .command(argv: [f.url("Applications/Docker.app/Contents/MacOS/uninstall").path]))
        let trashed = kinds.compactMap { if case .trash(let u) = $0 { u } else { nil } }.flatMap { $0 }
        #expect(Set(trashed.map(\.path)) == Set([
            f.url("Library/Containers/com.docker.docker"), f.url("Library/Group Containers/group.com.docker"),
            f.url(".docker"), f.url("Applications/Docker.app"),
            f.url("usr/local/bin/docker"), f.url("usr/local/bin/kubectl"),
        ].map(\.path)))
        guard case .copyToTerminal(let sudo) = kinds.last else { Issue.record("last step isn't a Terminal command"); return }
        #expect(sudo.contains("sudo rm"))
        #expect(sudo.contains("com.docker.vmnetd"))
        let firstTrash = kinds.firstIndex { if case .trash = $0 { true } else { false } }!
        #expect(firstTrash == 1)
        let trashedItems = items.filter { ["docker.data", "docker.group", "docker.config", "docker.app", "docker.links"].contains($0.id) }
        #expect(plan.expectedBytes == trashedItems.reduce(0) { $0 + $1.bytes })
    }

    @Test func dockerDaemonItems() async throws {
        let f = docker()
        let df = """
        {"Active":"2","Reclaimable":"2.1GB (65%)","Size":"3.2GB","TotalCount":"5","Type":"Images"}
        {"Active":"0","Reclaimable":"10MB (100%)","Size":"10MB","TotalCount":"3","Type":"Containers"}
        {"Active":"1","Reclaimable":"500MB (50%)","Size":"1GB","TotalCount":"4","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"1.5GB","Size":"1.5GB","TotalCount":"20","Type":"Build Cache"}
        """
        let r = FakeRunner(["docker info": FakeRunner.ok, "docker system df --format {{json .}}": FakeRunner.out(df)], tools: ["docker"])
        let items = await DockerProvider().scan(f.env(runner: r), pins: Pins())
        let daemon = items.filter { $0.id.hasPrefix("docker.df.") }
        #expect(daemon.count == 4)
        #expect(daemon.first { $0.id == "docker.df.volumes" }?.risk == .yourData)
        #expect(daemon.first { $0.id == "docker.df.images" }?.bytes == 2_100_000_000)
        let plan = await DockerProvider().plan(["docker.df.buildcache"], items: items, env: f.env(runner: r))
        #expect(plan.steps.map(\.kind) == [.command(argv: ["docker", "builder", "prune", "-a", "-f"])])
    }

    func xcode(selected: Bool, clt: Bool = true) -> (Fixture, FakeRunner) {
        let f = Fixture()
        let info: [String: Any] = ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": "13.3"]
        let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        f.file("Applications/Xcode.app/Contents/Info.plist", contents: String(decoding: data, as: UTF8.self))
        f.file("Applications/Xcode.app/Contents/Developer/big.bin", bytes: 100_000)
        f.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 10_000)
        if clt { f.dir("Library/Developer/CommandLineTools") }
        let devices = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-15-4":[
          {"udid":"AAA-111","name":"iPhone 13","state":"Shutdown","isAvailable":true},
          {"udid":"BBB-222","name":"iPad Air","state":"Booted","isAvailable":true}]}}
        """
        f.file("Library/Developer/CoreSimulator/Devices/AAA-111/data/x", bytes: 5000)
        let selectedPath = selected ? f.url("Applications/Xcode.app/Contents/Developer").path : "/Library/Developer/CommandLineTools"
        let r = FakeRunner([
            "xcode-select -p": FakeRunner.out(selectedPath + "\n"),
            "xcrun simctl list devices -j": FakeRunner.out(devices),
            "xcrun simctl runtime list -j": FakeRunner.out(#"{"X":{"identifier":"X","version":"15.4","platformIdentifier":"com.apple.platform.iphonesimulator","sizeBytes":7000000000}}"#),
        ], tools: ["xcrun", "xcode-select"])
        return (f, r)
    }

    @Test func xcodeSelectedRefused() async throws {
        let (f, r) = xcode(selected: true)
        let items = await XcodeProvider().scan(f.env(runner: r), pins: Pins())
        let app = try #require(items.first { $0.id == "xcode.app.Xcode.app" })
        #expect(app.title == "Xcode 13.3")
        #expect(app.badges.contains(.selectedByXcodeSelect))
        let plan = await XcodeProvider().plan([app.id], items: items, env: f.env(runner: r))
        #expect(plan.refusals.first?.reason == "Your developer tools point at this Xcode")
        #expect(plan.steps.map(\.kind) == [.copyToTerminal("sudo xcode-select -s /Library/Developer/CommandLineTools")])
    }

    @Test func xcodeSelectedWithoutCLT() async throws {
        let (f, r) = xcode(selected: true, clt: false)
        let items = await XcodeProvider().scan(f.env(runner: r), pins: Pins())
        let plan = await XcodeProvider().plan(["xcode.app.Xcode.app"], items: items, env: f.env(runner: r))
        #expect(plan.refusals.first?.reason == "Install the Command Line Tools first: xcode-select --install")
        #expect(plan.steps.isEmpty)
    }

    @Test func unselectedXcodeTrashed() async throws {
        let (f, r) = xcode(selected: false)
        let items = await XcodeProvider().scan(f.env(runner: r), pins: Pins())
        let plan = await XcodeProvider().plan(["xcode.app.Xcode.app", "xcode.deriveddata"], items: items, env: f.env(runner: r))
        #expect(plan.refusals.isEmpty)
        #expect(plan.steps.map(\.kind) == [.trash([f.url("Applications/Xcode.app")]), .trash([f.url("Library/Developer/Xcode/DerivedData")])])
    }

    @Test func simulatorsFromJSON() async throws {
        let (f, r) = xcode(selected: false)
        let items = await XcodeProvider().scan(f.env(runner: r), pins: Pins())
        let sims = items.filter { $0.id.hasPrefix("xcode.sim.") }
        #expect(sims.count == 2)
        #expect(sims.first { $0.id == "xcode.sim.BBB-222" }?.badges.contains(.running) == true)
        #expect(sims.first { $0.id == "xcode.sim.AAA-111" }?.bytes ?? 0 >= 5000)
        let plan = await XcodeProvider().plan(["xcode.sim.AAA-111"], items: items, env: f.env(runner: r))
        #expect(plan.steps.map(\.kind) == [.command(argv: ["xcrun", "simctl", "delete", "AAA-111"])])
        let runtime = try #require(items.first { $0.id == "xcode.runtime.X" })
        #expect(runtime.bytes == 7_000_000_000)
    }
}
