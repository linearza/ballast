import Foundation
import Testing
@testable import BallastCore

@Suite struct RuntimeProviderTests {
    /// RVM with 3.1.2, 3.2.0 and 4.0.5 (default); pilatsee pins 3.1.2.
    func rvm(default def: String = "4.0.5") -> Fixture {
        let f = Fixture()
        for v in ["3.1.2", "3.2.0", "4.0.5"] {
            f.file(".rvm/rubies/ruby-\(v)/bin/ruby", bytes: 10_000)
            f.file(".rvm/gems/ruby-\(v)/gems/rake/lib.rb", bytes: 20_000)
        }
        f.file(".rvm/gems/ruby-3.2.0@global/gems/bundler.rb", bytes: 5_000)
        f.file(".rvm/config/alias", contents: "default=ruby-\(def)\n")
        f.file(".rvm/src/ruby-3.2.0/configure", bytes: 30_000)
        f.file(".rvm/archives/ruby-3.2.0.tar.bz2", bytes: 30_000)
        f.file("Projects/pilatsee/.ruby-version", contents: "3.1.2\n")
        return f
    }

    func scan(_ p: any Provider, _ f: Fixture) async -> [Item] {
        await p.scan(f.env(), pins: scanPins(roots: [f.url("Projects")]))
    }

    @Test func rubyMarksDefaultAndPins() async throws {
        let f = rvm()
        let items = await scan(RubyProvider(), f)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let def = try #require(byID["ruby.rvm.4.0.5"])
        let pinned = try #require(byID["ruby.rvm.3.1.2"])
        let free = try #require(byID["ruby.rvm.3.2.0"])
        #expect(def.badges.contains(.isDefault))
        #expect(def.title == "Ruby 4.0.5")
        #expect(pinned.badges.contains(.pinned(by: ["pilatsee"])))
        #expect(!free.inUse)
        #expect(free.risk == .regenerable)
        #expect(byID["ruby.rvm.downloads"]?.risk == .regenerable)
    }

    @Test func rubyItemIncludesGems() async throws {
        let f = rvm()
        let item = try #require(await scan(RubyProvider(), f).first { $0.id == "ruby.rvm.3.2.0" })
        let paths = item.paths.map(\.path)
        #expect(paths.contains(f.url(".rvm/rubies/ruby-3.2.0").path))
        #expect(paths.contains(f.url(".rvm/gems/ruby-3.2.0").path))
        #expect(paths.contains(f.url(".rvm/gems/ruby-3.2.0@global").path))
        #expect(item.bytes >= 35_000)
    }

    @Test func rubyPlanUsesRvm() async {
        let f = rvm()
        let items = await scan(RubyProvider(), f)
        let plan = await RubyProvider().plan(["ruby.rvm.3.2.0"], items: items, env: f.env())
        #expect(plan.steps.count == 1)
        guard case .shell(let script) = plan.steps.first?.kind else { Issue.record("not a shell step"); return }
        #expect(script.contains("rvm remove ruby-3.2.0 --gems"))
        #expect(script.contains("source \(f.url(".rvm/scripts/rvm").path)"))
        #expect(plan.expectedBytes == items.first { $0.id == "ruby.rvm.3.2.0" }!.bytes)
        #expect(plan.warnings.isEmpty)
    }

    @Test func planRefusesNothingButWarnsInUse() async {
        let f = rvm()
        let items = await scan(RubyProvider(), f)
        let plan = await RubyProvider().plan(["ruby.rvm.4.0.5", "ruby.rvm.3.1.2"], items: items, env: f.env())
        #expect(plan.refusals.isEmpty)
        #expect(plan.steps.count == 2)
        #expect(plan.warnings.contains { $0.contains("default") })
        #expect(plan.warnings.contains { $0.contains("pilatsee") })
    }

    @Test func rvmImplodeAction() async throws {
        let f = rvm()
        let items = await scan(RubyProvider(), f)
        let action = try #require(RubyProvider().extraActions(items).first)
        #expect(action.title == "Uninstall RVM completely")
        let plan = await RubyProvider().plan([action.id], items: items, env: f.env())
        guard case .shell(let script) = plan.steps.first?.kind else { Issue.record("not a shell step"); return }
        #expect(script.contains("rvm implode --force"))
        #expect(plan.warnings.contains { $0.contains("every Ruby") })
        #expect(plan.expectedBytes >= items.reduce(0) { $0 + $1.bytes })
    }

    @Test func rbenvAndAsdf() async throws {
        let f = Fixture()
        f.file(".rbenv/versions/3.3.0/bin/ruby", bytes: 1000)
        f.file(".rbenv/version", contents: "3.3.0\n")
        f.file(".asdf/installs/ruby/3.2.2/bin/ruby", bytes: 1000)
        let items = await scan(RubyProvider(), f)
        #expect(items.first { $0.id == "ruby.rbenv.3.3.0" }?.badges.contains(.isDefault) == true)
        let plan = await RubyProvider().plan(["ruby.asdf.3.2.2"], items: items, env: f.env())
        #expect(plan.steps.first?.kind == .command(argv: ["asdf", "uninstall", "ruby", "3.2.2"]))
    }

    @Test func nodeResolvesDefaultAlias() async {
        let f = Fixture()
        for v in ["v16.0.0", "v18.17.1", "v24.15.0"] { f.file(".nvm/versions/node/\(v)/bin/node", bytes: 1000) }
        f.file(".nvm/alias/default", contents: "24\n")
        let items = await scan(NodeProvider(), f)
        #expect(items.first { $0.id == "node.nvm.v24.15.0" }?.badges.contains(.isDefault) == true)
        #expect(items.first { $0.id == "node.nvm.v16.0.0" }?.inUse == false)
        #expect(items.first { $0.id == "node.nvm.v24.15.0" }?.title == "Node 24.15.0")
    }

    @Test func nodeDefaultFollowsNamedAliases() async {
        let f = Fixture()
        for v in ["v18.19.1", "v20.19.0"] { f.file(".nvm/versions/node/\(v)/bin/node", bytes: 1000) }
        f.file(".nvm/alias/default", contents: "lts/iron\n")
        f.file(".nvm/alias/lts/iron", contents: "v20.19.0\n")
        let items = await scan(NodeProvider(), f)
        #expect(items.first { $0.id == "node.nvm.v20.19.0" }?.badges.contains(.isDefault) == true)
    }

    @Test func nodePlanUsesNvm() async {
        let f = Fixture()
        f.file(".nvm/versions/node/v16.0.0/bin/node", bytes: 1000)
        f.file(".nvm/.cache/bin/node-v16.tar.gz", bytes: 1000)
        let items = await scan(NodeProvider(), f)
        let plan = await NodeProvider().plan(["node.nvm.v16.0.0", "node.nvm.cache"], items: items, env: f.env())
        let scripts = plan.steps.compactMap { if case .shell(let s) = $0.kind { s } else { nil } }
        #expect(scripts.contains { $0.contains("nvm uninstall v16.0.0") })
        #expect(scripts.contains { $0.contains("nvm cache clear") })
    }

    @Test func pythonPyenvAndVenvs() async {
        let f = Fixture()
        f.file(".pyenv/versions/3.11.4/bin/python", bytes: 1000)
        f.file(".pyenv/version", contents: "3.11.4\n")
        f.file(".pyenv/versions/3.9.1/bin/python", bytes: 1000)
        f.file(".venvs/scratch/bin/python", bytes: 1000)
        let items = await scan(PythonProvider(), f)
        #expect(items.first { $0.id == "python.pyenv.3.11.4" }?.badges.contains(.isDefault) == true)
        #expect(items.first { $0.id == "python.venv.scratch" }?.risk == .review)
        let plan = await PythonProvider().plan(["python.pyenv.3.9.1", "python.venv.scratch"], items: items, env: f.env())
        #expect(plan.steps.map(\.kind) == [
            .command(argv: ["pyenv", "uninstall", "-f", "3.9.1"]),
            .trash([f.url(".venvs/scratch")]),
        ])
    }

    @Test func recheckCatchesNewDefault() async throws {
        let f = rvm()
        let pins = scanPins(roots: [f.url("Projects")])
        let item = try #require(await RubyProvider().scan(f.env(), pins: pins).first { $0.id == "ruby.rvm.3.2.0" })
        #expect(await RubyProvider().recheck([item], env: f.env(), pins: pins).isEmpty)
        f.file(".rvm/config/alias", contents: "default=ruby-3.2.0\n")
        let refusal = await RubyProvider().recheck([item], env: f.env(), pins: pins)[item.id]
        #expect(refusal?.reason == "Now the default Ruby")
    }

    @Test func absentWhenNoTools() async {
        let f = Fixture()
        #expect(await RubyProvider().isPresent(f.env()) == false)
        #expect(await NodeProvider().isPresent(f.env()) == false)
    }

    @Test func symlinkedVersionsAreNotItems() async {
        let f = rvm()
        f.link(".rvm/rubies/default", to: f.url(".rvm/rubies/ruby-4.0.5").path)
        let items = await scan(RubyProvider(), f)
        #expect(!items.contains { $0.id == "ruby.rvm.default" })
    }
}
