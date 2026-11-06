import Darwin
import Foundation
import Testing
@testable import BallastCore

private func sample(pid: Int32, path: String?, args: [String] = [], cwd: String? = nil, bytes: Int64) -> ProcessSample {
    ProcessSample(pid: pid, startSeconds: 1, uid: 501, path: path, args: args, cwd: cwd, footprint: bytes)
}

private extension ProcessSample {
    func with(pid: Int32) -> ProcessSample {
        ProcessSample(pid: pid, startSeconds: startSeconds, uid: uid, path: path, args: args, cwd: cwd, footprint: footprint)
    }
}

@Suite struct MemoryGroupsTests {
    @Test func helpersCountAsTheOutermostApp() {
        let p = "/Applications/Brave Browser.app/Contents/Frameworks/B.framework/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/x"
        let g = groupProcesses([sample(pid: 1, path: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", bytes: 10), sample(pid: 2, path: p, bytes: 5)])
        #expect(g.count == 1)
        #expect(g[0].name == "Brave Browser")
        #expect(g[0].bytes == 15)
    }

    @Test func vitestWorkersShowAsVitest() {
        let w = sample(pid: 1, path: "/opt/node/bin/node", args: ["node", "/r/node_modules/vitest/dist/workers/forks.js"], cwd: "/r", bytes: 4)
        #expect(groupProcesses([w, w.with(pid: 2)])[0].name == "vitest · r")
    }

    @Test func pnpmStoreSegmentIsSkipped() {
        let w = sample(pid: 1, path: "/opt/node/bin/node", args: ["node", "/r/node_modules/.pnpm/vitest@1/node_modules/vitest/dist/x.js"], cwd: "/r", bytes: 4)
        #expect(groupProcesses([w])[0].name == "vitest · r")
    }

    @Test func binShimsNameTheToolNotBin() {
        let a = sample(pid: 1, path: "/opt/node/bin/node", args: ["node", "/r/node_modules/.bin/vite"], cwd: "/r", bytes: 1)
        let b = sample(pid: 2, path: "/opt/node/bin/node", args: ["node", "/r/node_modules/.bin/tsc"], cwd: "/r", bytes: 1)
        #expect(Set(groupProcesses([a, b]).map(\.name)) == ["vite · r", "tsc · r"])
    }

    @Test func unrelatedNodeStaysApart() {
        let g = groupProcesses([
            sample(pid: 1, path: "/opt/node/bin/node", args: ["node", "a.js"], cwd: "/p/one", bytes: 1),
            sample(pid: 2, path: "/opt/node/bin/node", args: ["node", "b.js"], cwd: "/p/two", bytes: 1),
        ])
        #expect(g.count == 2)
        #expect(Set(g.map(\.name)) == ["node · one", "node · two"])
    }

    @Test func runtimeWithoutCwdIsJustTheRuntime() {
        let g = groupProcesses([sample(pid: 1, path: "/usr/bin/python3", args: ["python3", "x.py"], bytes: 1)])
        #expect(g[0].name == "python3")
    }

    @Test func plainToolsGroupByExecutable() {
        let g = groupProcesses([sample(pid: 1, path: "/usr/local/bin/foo", bytes: 1), sample(pid: 2, path: "/usr/local/bin/foo", bytes: 2)])
        #expect(g.count == 1)
        #expect(g[0].name == "foo")
        #expect(g[0].bytes == 3)
    }

    @Test func missingPathGroupsAsUnknown() {
        let g = groupProcesses([sample(pid: 1, path: nil, bytes: 1), sample(pid: 2, path: nil, bytes: 1)])
        #expect(g.count == 1)
        #expect(g[0].name == "Unknown process")
    }

    @Test func groupsAreLargestFirst() {
        let g = groupProcesses([sample(pid: 1, path: "/bin/a", bytes: 1), sample(pid: 2, path: "/bin/b", bytes: 9)])
        #expect(g.map(\.name) == ["b", "a"])
    }

    @Test func percentHandlesZeroPhysical() {
        #expect(SystemMemory(physical: 0, used: 0, swapUsed: 0).usedPercent == nil)
    }

    @Test func percentRoundsAndClamps() {
        #expect(SystemMemory(physical: 1000, used: 505, swapUsed: 0).usedPercent == 51)
        #expect(SystemMemory(physical: 1000, used: 2000, swapUsed: 0).usedPercent == 100)
        #expect(SystemMemory(physical: 1000, used: -5, swapUsed: 0).usedPercent == 0)
    }
}

/// A KERN_PROCARGS2 buffer: argc, exec path, padding NULs, then the argv strings, each NUL-terminated.
private func procArgs(argc: Int32, exec: String, strings: [String], padding: Int = 3) -> [UInt8] {
    var buf: [UInt8] = withUnsafeBytes(of: argc) { Array($0) }
    buf += Array(exec.utf8) + [0] + [UInt8](repeating: 0, count: padding)
    for s in strings { buf += Array(s.utf8) + [0] }
    return buf
}

@Suite struct ProcessArgumentsParsingTests {
    @Test func normalArgv() {
        let buf = procArgs(argc: 3, exec: "/opt/node/bin/node", strings: ["node", "/r/node_modules/vitest/dist/cli.js", "run"])
        #expect(parseProcessArguments(buf) == ["node", "/r/node_modules/vitest/dist/cli.js", "run"])
    }

    @Test func wipedArgvComesBackAsTheTitleThenEmpties() {
        // process.title = "node (vitest 1)" overwrites the argv area; argc stays 4.
        let buf = procArgs(argc: 4, exec: "/opt/node/bin/node", strings: ["node (vitest 1)", "", "", ""])
        #expect(parseProcessArguments(buf) == ["node (vitest 1)", "", "", ""])
    }

    @Test func truncatedDataGivesWhatIsThere() {
        let full = procArgs(argc: 3, exec: "/opt/node/bin/node", strings: ["node", "script.js", "extra"])
        #expect(parseProcessArguments(Array(full.dropLast(3))) == ["node", "script.js", "ext"])
        #expect(parseProcessArguments(Array(full.prefix(4))) == [])
        #expect(parseProcessArguments(Array(full.prefix(2))) == [])
        #expect(parseProcessArguments([]) == [])
        #expect(parseProcessArguments(procArgs(argc: 2, exec: "/x", strings: [])) == [])
        #expect(parseProcessArguments(procArgs(argc: -1, exec: "/x", strings: ["a"])) == [])
    }
}

@Suite struct ProcessTitleGroupingTests {
    private let node = "/opt/node/bin/node"

    private func titled(_ pid: Int32, _ title: String, cwd: String? = "/Users/me/Projects/heyanna") -> ProcessSample {
        sample(pid: pid, path: node, args: [title, "", "", ""], cwd: cwd, bytes: 5)
    }

    @Test func wipedVitestWorkersNameVitest() {
        let g = groupProcesses([titled(1, "node (vitest 1)"), titled(2, "node (vitest 2)"), titled(3, "node (vitest)")])
        #expect(g.count == 1)
        #expect(g[0].name == "vitest · heyanna")
        #expect(g[0].processes.count == 3)
    }

    @Test func titledVitestAndMcpServerStayApart() {
        let g = groupProcesses([titled(1, "node (vitest 1)"), titled(2, "chrome-devtools-mcp"), titled(3, "npm")])
        #expect(Set(g.map(\.name)) == ["vitest · heyanna", "chrome-devtools-mcp · heyanna", "npm · heyanna"])
    }

    @Test func liveShapeTitleCutShortWithEnvironmentLeakingIn() {
        // Seen on a real macOS: the title is clipped to the old argv length (no closing paren) and the next
        // "argument" is an environment string.
        let w = sample(pid: 1, path: node, args: ["node (vitest 1", "TERM_SESSION_ID=abc"], cwd: "/Users/me/heyanna", bytes: 1)
        #expect(groupProcesses([w])[0].name == "vitest · heyanna")
        #expect(processLabel(w) == "vitest")
    }

    @Test func trailingColonIsDropped() {
        #expect(groupProcesses([titled(1, "puma: cluster worker 0")])[0].name == "puma · heyanna")
        #expect(groupProcesses([titled(1, "puma:")])[0].name == "puma · heyanna")
    }

    @Test func titleWithoutFolderIsJustTheName() {
        #expect(groupProcesses([titled(1, "node (vitest 1)", cwd: nil)])[0].name == "vitest")
        #expect(groupProcesses([titled(1, "node (vitest 1)", cwd: "/")])[0].name == "vitest")
    }

    @Test func bareRuntimeNameIsNotATitle() {
        let g = groupProcesses([sample(pid: 1, path: node, args: ["node", "a.js"], cwd: "/p/one", bytes: 1)])
        #expect(g[0].name == "node · one")
        let py = groupProcesses([sample(pid: 1, path: "/usr/bin/python3", args: ["python3", "x.py"], cwd: "/p/one", bytes: 1)])
        #expect(py[0].name == "python3 · one")
    }

    @Test func pathArgv0IsNotATitle() {
        let g = groupProcesses([sample(pid: 1, path: node, args: ["/opt/node/bin/node", "a.js"], cwd: "/p/one", bytes: 1)])
        #expect(g[0].name == "node · one")
    }

    @Test func toolGroupsAreSeparatePerFolder() {
        let a = sample(pid: 1, path: node, args: ["node", "/r1/node_modules/vitest/dist/x.js"], cwd: "/r1", bytes: 1)
        let b = sample(pid: 2, path: node, args: ["node", "/r2/node_modules/vitest/dist/x.js"], cwd: "/r2", bytes: 1)
        let g = groupProcesses([a, b])
        #expect(g.count == 2)
        #expect(Set(g.map(\.name)) == ["vitest · r1", "vitest · r2"])
        #expect(Set(g.map(\.id)) == ["tool:vitest:/r1", "tool:vitest:/r2"])
    }

    @Test func toolWithoutFolderIsJustTheName() {
        let a = sample(pid: 1, path: node, args: ["node", "/r1/node_modules/vitest/dist/x.js"], cwd: nil, bytes: 1)
        #expect(groupProcesses([a])[0].name == "vitest")
    }

    @Test func labelsNameTheProcessUsefully() {
        #expect(processLabel(titled(1, "node (vitest 1)")) == "vitest")
        #expect(processLabel(titled(1, "chrome-devtools-mcp")) == "chrome-devtools-mcp")
        #expect(processLabel(sample(pid: 1, path: node, args: ["node", "/r/node_modules/.bin/tsc"], cwd: "/r", bytes: 1)) == "tsc")
        #expect(processLabel(sample(pid: 1, path: node, args: ["node", "--inspect", "/p/server.js"], cwd: "/p", bytes: 1)) == "node server.js")
        #expect(processLabel(sample(pid: 1, path: "/usr/local/bin/foo", bytes: 1)) == "foo")
        #expect(processLabel(sample(pid: 1, path: nil, bytes: 1)) == "unknown")
    }

    @Test func homeBecomesTilde() {
        #expect(abbreviatingHome("/Users/me/Projects/heyanna", home: "/Users/me") == "~/Projects/heyanna")
        #expect(abbreviatingHome("/Users/me", home: "/Users/me") == "~")
        #expect(abbreviatingHome("/Users/meh/x", home: "/Users/me") == "/Users/meh/x")
        #expect(abbreviatingHome("/opt/x", home: "/Users/me") == "/opt/x")
    }
}

@Suite struct LiveMemoryReaderTests {
    @Test func nonexistentPidIsSkipped() {
        #expect(LiveMemoryReader.sample(pid: Int32.max) == nil)
    }

    @Test func listsAllReadableProcesses() {
        let total = Int(proc_listallpids(nil, 0))
        let got = LiveMemoryReader().processes().count
        #expect(total > 0)
        #expect(Double(got) >= Double(total) * 0.5)
    }

    @Test func seesItself() {
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = LiveMemoryReader().processes().first { $0.pid == me }
        #expect(mine != nil)
        #expect((mine?.footprint ?? 0) > 0)
    }

    @Test func systemMemoryIsPlausible() {
        let s = LiveMemoryReader().system()
        #expect(s?.usedPercent != nil)
        #expect((s?.physical ?? 0) > 0)
    }
}
