import Foundation
import Testing
@testable import BallastCore

@Suite struct PinsTests {
    func projects() -> Fixture {
        let f = Fixture()
        f.file("Projects/pilatsee/.ruby-version", contents: "ruby-3.3.4\n")
        f.file("Projects/dentally/houston/.nvmrc", contents: "v12.13.1\n")
        f.file("Projects/multi/.tool-versions", contents: "ruby 3.1.2\nnodejs 20.16.0\npython 3.11.4\n")
        f.file("Projects/gemmy/Gemfile", contents: "source 'https://rubygems.org'\nruby \"3.2.2\"\ngem 'rails'\n")
        f.file("Projects/nodey/.node-version", contents: "18.19\n")
        f.file("Projects/engines/package.json", contents: #"{"engines":{"node":"20"},"volta":{"node":"20.19.0"}}"#)
        f.file("Projects/ranged/package.json", contents: #"{"engines":{"node":">=18"}}"#)
        f.file("Projects/snake/.python-version", contents: "3.12.1\n")
        f.file("Projects/web/node_modules/dep/.nvmrc", contents: "8\n")
        return f
    }

    @Test func readsAllPinFiles() {
        let f = projects()
        let pins = scanPins(roots: [f.url("Projects")])
        #expect(pins.ruby["3.3.4"] == ["pilatsee"])
        #expect(pins.ruby["3.1.2"] == ["multi"])
        #expect(pins.ruby["3.2.2"] == ["gemmy"])
        #expect(pins.node["12.13.1"] == ["dentally/houston"])
        #expect(pins.node["20.16.0"] == ["multi"])
        #expect(pins.node["18.19"] == ["nodey"])
        #expect(pins.node["20"] == ["engines"])
        #expect(pins.node["20.19.0"] == ["engines"])
        #expect(pins.python["3.11.4"] == ["multi"])
        #expect(pins.python["3.12.1"] == ["snake"])
    }

    @Test func stripsPrefixes() {
        #expect(versionMatches(pin: "v12.13.1", installed: "12.13.1"))
        #expect(versionMatches(pin: "ruby-3.3.4", installed: "3.3.4"))
        #expect(versionMatches(pin: "3.3.4", installed: "ruby-3.3.4"))
        #expect(versionMatches(pin: "22", installed: "v22.11.0"))
        #expect(versionMatches(pin: "18.19", installed: "18.19.1"))
        #expect(!versionMatches(pin: "18.19", installed: "18.17.1"))
        #expect(!versionMatches(pin: "1", installed: "12.0.0"))
        #expect(!versionMatches(pin: "3.3.4.1", installed: "3.3.4"))
    }

    @Test func semverRangeEngines() {
        let f = projects()
        let pins = scanPins(roots: [f.url("Projects")])
        #expect(pins.node.values.flatMap { $0 }.contains("ranged") == false)
    }

    @Test func ignoresNodeModules() {
        let f = projects()
        let pins = scanPins(roots: [f.url("Projects")])
        #expect(pins.node["8"] == nil)
    }

    @Test func pinnersMatchInstalledVersion() {
        let f = projects()
        let pins = scanPins(roots: [f.url("Projects")])
        #expect(pins.pinners(of: pins.node, installed: "v20.16.0") == ["engines", "multi"])
        #expect(pins.pinners(of: pins.node, installed: "v24.15.0") == [])
    }

    @Test func detectsRoots() {
        let f = Fixture()
        f.dir("Projects/a/.git"); f.dir("Projects/b/.git")
        f.dir("code/only/.git")
        f.dir("src/notgit")
        #expect(detectProjectRoots(home: f.root) == [f.url("Projects")])
    }
}
