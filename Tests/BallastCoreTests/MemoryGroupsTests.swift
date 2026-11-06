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
        #expect(groupProcesses([w, w.with(pid: 2)])[0].name == "vitest")
    }

    @Test func pnpmStoreSegmentIsSkipped() {
        let w = sample(pid: 1, path: "/opt/node/bin/node", args: ["node", "/r/node_modules/.pnpm/vitest@1/node_modules/vitest/dist/x.js"], cwd: "/r", bytes: 4)
        #expect(groupProcesses([w])[0].name == "vitest")
    }

    @Test func binShimsNameTheToolNotBin() {
        let a = sample(pid: 1, path: "/opt/node/bin/node", args: ["node", "/r/node_modules/.bin/vite"], cwd: "/r", bytes: 1)
        let b = sample(pid: 2, path: "/opt/node/bin/node", args: ["node", "/r/node_modules/.bin/tsc"], cwd: "/r", bytes: 1)
        #expect(Set(groupProcesses([a, b]).map(\.name)) == ["vite", "tsc"])
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
