import Foundation
import Testing
@testable import BallastCore

/// Version managers added in 0.2.0.
@Suite struct MoreToolchainsTests {
    func byID(_ items: [Item]) -> [String: Item] { Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }) }

    func firstKind(_ p: any Provider, _ id: String, _ items: [Item], _ env: Environment) async -> StepKind? {
        await p.plan([id], items: items, env: env).steps.first?.kind
    }

    // MARK: Ruby

    @Test func chrubyAndFrum() async throws {
        let f = Fixture()
        f.file(".rubies/ruby-3.3.0/bin/ruby", bytes: 10)
        f.file(".frum/versions/3.2.2/bin/ruby", bytes: 10)
        f.file("Projects/app/.ruby-version", contents: "3.3.0\n")
        let env = f.env()
        let items = await RubyProvider().scan(env, pins: scanPins(roots: [f.url("Projects")]))
        let m = byID(items)
        #expect(m["ruby.chruby.3.3.0"]?.badges.contains(.pinned(by: ["app"])) == true)
        #expect(m["ruby.frum.3.2.2"] != nil)
        #expect(await firstKind(RubyProvider(), "ruby.chruby.3.3.0", items, env) == .trash([f.url(".rubies/ruby-3.3.0")]))
        #expect(await firstKind(RubyProvider(), "ruby.frum.3.2.2", items, env) == .command(argv: ["frum", "uninstall", "3.2.2"]))
    }

    // MARK: Node

    @Test func nAndNodenv() async throws {
        let f = Fixture()
        f.file("usr/local/n/versions/node/18.20.0/bin/node", bytes: 10)
        f.file(".nodenv/versions/20.11.0/bin/node", bytes: 10)
        f.file(".nodenv/version", contents: "20.11.0\n")
        let env = f.env()
        let items = await NodeProvider().scan(env, pins: Pins())
        let m = byID(items)
        #expect(m["node.n.18.20.0"]?.title == "Node 18.20.0")
        #expect(m["node.nodenv.20.11.0"]?.badges.contains(.isDefault) == true)
        #expect(await firstKind(NodeProvider(), "node.n.18.20.0", items, env) == .command(argv: ["n", "rm", "18.20.0"]))
        #expect(await firstKind(NodeProvider(), "node.nodenv.20.11.0", items, env) == .command(argv: ["nodenv", "uninstall", "-f", "20.11.0"]))
    }

    // MARK: Python

    @Test func uvPythons() async throws {
        let f = Fixture()
        f.file(".local/share/uv/python/cpython-3.12.4-macos-aarch64-none/bin/python3", bytes: 10)
        f.file("Projects/app/.python-version", contents: "3.12\n")
        let env = f.env()
        let items = await PythonProvider().scan(env, pins: scanPins(roots: [f.url("Projects")]))
        let uv = try #require(items.first { $0.id == "python.uv.cpython-3.12.4-macos-aarch64-none" })
        #expect(uv.title == "Python 3.12.4")
        #expect(uv.badges.contains(.pinned(by: ["app"])))
        #expect(await firstKind(PythonProvider(), uv.id, items, env) == .command(argv: ["uv", "python", "uninstall", "3.12.4"]))
    }

    @Test func condaPipxAndProjectVirtualenvs() async throws {
        let f = Fixture()
        f.file("miniforge3/envs/ml/bin/python", bytes: 10)
        f.file(".local/pipx/venvs/black/bin/black", bytes: 10)
        f.file("Library/Caches/pypoetry/virtualenvs/app-x1y2-py3.12/bin/python", bytes: 10)
        f.file(".local/share/virtualenvs/site-abc123/bin/python", bytes: 10)
        f.file("Library/Application Support/hatch/env/virtual/tool/abc/bin/python", bytes: 10)
        let runner = FakeRunner(tools: ["conda", "pipx"])
        let env = f.env(runner: runner)
        let items = await PythonProvider().scan(env, pins: Pins())
        let m = byID(items)
        #expect(m["python.conda.ml"]?.risk == .review)
        #expect(m["python.pipx.black"]?.risk == .review)
        #expect(m["python.poetry.app-x1y2-py3.12"]?.risk == .regenerable)
        #expect(m["python.pipenv.site-abc123"]?.risk == .regenerable)
        #expect(m["python.hatch.tool"]?.risk == .regenerable)
        #expect(await firstKind(PythonProvider(), "python.conda.ml", items, env)
                == .command(argv: ["conda", "env", "remove", "-y", "-p", f.url("miniforge3/envs/ml").path]))
        #expect(await firstKind(PythonProvider(), "python.pipx.black", items, env) == .command(argv: ["pipx", "uninstall", "black"]))
        #expect(await firstKind(PythonProvider(), "python.pipenv.site-abc123", items, env) == .trash([f.url(".local/share/virtualenvs/site-abc123")]))
    }

    // MARK: Other languages

    @Test func javaVersions() async throws {
        let f = Fixture()
        f.file(".sdkman/candidates/java/21.0.2-tem/release", contents: "JAVA_VERSION=\"21.0.2\"\n")
        f.file(".sdkman/candidates/java/17.0.10-tem/release", contents: "JAVA_VERSION=\"17.0.10\"\n")
        f.link(".sdkman/candidates/java/current", to: ".sdkman/candidates/java/21.0.2-tem")
        f.file("Library/Java/JavaVirtualMachines/temurin-11.jdk/Contents/Home/release", contents: "JAVA_VERSION=\"11.0.22\"\n")
        f.file("Projects/svc/.java-version", contents: "17\n")
        let env = f.env()
        let p = LanguagesProvider()
        let items = await p.scan(env, pins: scanPins(roots: [f.url("Projects")]))
        let m = byID(items)
        #expect(Set(m.keys) == ["lang.sdkman.java.21.0.2-tem", "lang.sdkman.java.17.0.10-tem", "lang.jvm.temurin-11.jdk"])
        #expect(m["lang.sdkman.java.21.0.2-tem"]?.badges.contains(.isDefault) == true)
        #expect(m["lang.sdkman.java.17.0.10-tem"]?.badges.contains(.pinned(by: ["svc"])) == true)
        #expect(m["lang.jvm.temurin-11.jdk"]?.title == "Java 11.0.22")
        guard case .shell(let script) = await firstKind(p, "lang.sdkman.java.17.0.10-tem", items, env) else { Issue.record("not shell"); return }
        #expect(script.hasSuffix("sdk uninstall java 17.0.10-tem"))
        // A JDK for all users needs an administrator, so it's a command to copy.
        guard case .copyToTerminal(let cmd) = await firstKind(p, "lang.jvm.temurin-11.jdk", items, env) else { Issue.record("not copy"); return }
        #expect(cmd.hasPrefix("sudo rm -rf "))
    }

    @Test func goRustAndAsdf() async throws {
        let f = Fixture()
        f.file(".goenv/versions/1.21.5/bin/go", bytes: 10)
        f.file(".goenv/version", contents: "1.22.0\n")
        f.file(".goenv/versions/1.22.0/bin/go", bytes: 10)
        f.file(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc", bytes: 10)
        f.file(".rustup/toolchains/1.75.0-aarch64-apple-darwin/bin/rustc", bytes: 10)
        f.file(".rustup/settings.toml", contents: "default_toolchain = \"stable-aarch64-apple-darwin\"\nprofile = \"default\"\n")
        f.file(".asdf/installs/elixir/1.16.0/bin/elixir", bytes: 10)
        f.file(".local/share/mise/installs/erlang/26.2/bin/erl", bytes: 10)
        f.file("Projects/cli/rust-toolchain.toml", contents: "[toolchain]\nchannel = \"1.75.0\"\n")
        f.file("Projects/web/.tool-versions", contents: "golang 1.21.5\n")
        let env = f.env()
        let p = LanguagesProvider()
        let items = await p.scan(env, pins: scanPins(roots: [f.url("Projects")]))
        let m = byID(items)
        #expect(m["lang.goenv.go.1.22.0"]?.badges.contains(.isDefault) == true)
        #expect(m["lang.goenv.go.1.21.5"]?.badges.contains(.pinned(by: ["web"])) == true)
        #expect(m["lang.rustup.rust.stable-aarch64-apple-darwin"]?.badges.contains(.isDefault) == true)
        #expect(m["lang.rustup.rust.1.75.0-aarch64-apple-darwin"]?.badges.contains(.pinned(by: ["cli"])) == true)
        #expect(m["lang.asdf.elixir.1.16.0"]?.title == "Elixir 1.16.0")
        #expect(m["lang.mise.erlang.26.2"]?.title == "Erlang 26.2")
        #expect(await firstKind(p, "lang.goenv.go.1.21.5", items, env) == .command(argv: ["goenv", "uninstall", "-f", "1.21.5"]))
        #expect(await firstKind(p, "lang.rustup.rust.1.75.0-aarch64-apple-darwin", items, env)
                == .command(argv: ["rustup", "toolchain", "uninstall", "1.75.0-aarch64-apple-darwin"]))
        #expect(await firstKind(p, "lang.asdf.elixir.1.16.0", items, env) == .command(argv: ["asdf", "uninstall", "elixir", "1.16.0"]))
        #expect(await firstKind(p, "lang.mise.erlang.26.2", items, env) == .command(argv: ["mise", "uninstall", "erlang@26.2"]))
    }

    @Test func pinnedLanguageVersionsNeedAcknowledgingLikeRuby() async throws {
        let f = Fixture()
        f.file(".goenv/versions/1.21.5/bin/go", bytes: 10)
        f.file("Projects/web/.go-version", contents: "1.21.5\n")
        let env = f.env()
        let pins = scanPins(roots: [f.url("Projects")])
        let items = await LanguagesProvider().scan(env, pins: pins)
        let plan = await LanguagesProvider().plan(items.map(\.id), items: items, env: env)
        #expect(plan.refusals.isEmpty)
        #expect(plan.dangers.contains { $0.contains("web") })
    }
}
