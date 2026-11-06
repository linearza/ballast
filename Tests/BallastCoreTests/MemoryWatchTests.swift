import Testing
import Foundation
@testable import BallastCore

private let gb: Int64 = 1_073_741_824
private let phys: Int64 = 16 * gb
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func sys(usedPercent: Int, swap: Int64 = 0) -> SystemMemory {
    SystemMemory(physical: phys, used: phys * Int64(usedPercent) / 100, swapUsed: swap)
}

private func group(_ id: String, percent: Int) -> MemoryGroup {
    MemoryGroup(id: id, name: id, processes: [], bytes: phys * Int64(percent) / 100)
}

@Suite struct MemoryWatchTests {
    @Test func pressureGoesRed() {
        var w = MemoryWatch()
        w.update(system: sys(usedPercent: 20), pressure: .critical, topGroupBytes: nil, now: t0)
        #expect(w.isRed)
        var w2 = MemoryWatch()
        w2.update(system: sys(usedPercent: 20), pressure: .warning, topGroupBytes: nil, now: t0)
        #expect(w2.isRed)
    }

    @Test func seventyPercentHogGoesRed() {
        var w = MemoryWatch()
        w.update(system: sys(usedPercent: 80), pressure: .normal, topGroupBytes: phys * 70 / 100, now: t0)
        #expect(w.isRed)
    }

    @Test func fiftyPercentIsTheLine() {
        var a = MemoryWatch()
        a.update(system: sys(usedPercent: 60), pressure: .normal, topGroupBytes: phys * 49 / 100, now: t0)
        #expect(!a.isRed)
        var b = MemoryWatch()
        b.update(system: sys(usedPercent: 60), pressure: .normal, topGroupBytes: phys * 50 / 100, now: t0)
        #expect(b.isRed)
    }

    @Test func jumpGoesRed() {
        func run(from: Int, to: Int, seconds: Double) -> Bool {
            var w = MemoryWatch()
            w.update(system: sys(usedPercent: from), pressure: .normal, topGroupBytes: nil, now: t0)
            w.update(system: sys(usedPercent: to), pressure: .normal, topGroupBytes: nil, now: t0.addingTimeInterval(seconds))
            return w.isRed
        }
        #expect(run(from: 77, to: 92, seconds: 60))     // fast, and ends nearly full
        #expect(!run(from: 30, to: 55, seconds: 60))    // fast but ends with plenty free
        #expect(!run(from: 77, to: 92, seconds: 300))   // ends nearly full but too slow
        #expect(!run(from: 80, to: 90, seconds: 60))    // ends nearly full but only 10 points
    }

    @Test func staysRedAtLeastAMinute() {
        var w = MemoryWatch()
        w.update(system: sys(usedPercent: 20), pressure: .critical, topGroupBytes: nil, now: t0)
        w.update(system: sys(usedPercent: 20), pressure: .normal, topGroupBytes: nil, now: t0.addingTimeInterval(30))
        #expect(w.isRed)
        w.update(system: sys(usedPercent: 20), pressure: .normal, topGroupBytes: nil, now: t0.addingTimeInterval(61))
        #expect(!w.isRed)
    }

    @Test func doesNotFlickerBetweenThresholds() {
        var w = MemoryWatch()
        w.update(system: sys(usedPercent: 70), pressure: .normal, topGroupBytes: phys * 55 / 100, now: t0)
        #expect(w.isRed)
        w.update(system: sys(usedPercent: 60), pressure: .normal, topGroupBytes: phys * 45 / 100, now: t0.addingTimeInterval(200))
        #expect(w.isRed)
        w.update(system: sys(usedPercent: 50), pressure: .normal, topGroupBytes: phys * 39 / 100, now: t0.addingTimeInterval(260))
        #expect(!w.isRed)
    }

    @Test func breakdownSkippedWhenCalm() {
        let w = MemoryWatch()
        #expect(!w.needsBreakdown(system: sys(usedPercent: 30), pressure: .normal, now: t0))
    }

    @Test func breakdownRunsWhenHogPossible() {
        let w = MemoryWatch()
        #expect(w.needsBreakdown(system: sys(usedPercent: 50), pressure: .normal, now: t0))
        #expect(w.needsBreakdown(system: sys(usedPercent: 30), pressure: .warning, now: t0))
        var j = MemoryWatch()
        j.update(system: sys(usedPercent: 40), pressure: .normal, topGroupBytes: nil, now: t0)
        #expect(!j.needsBreakdown(system: sys(usedPercent: 49), pressure: .normal, now: t0.addingTimeInterval(30)))
    }

    @Test func breakdownRunsWhileRedAndHoldsTheBand() {
        var w = MemoryWatch()
        w.update(system: sys(usedPercent: 70), pressure: .normal, topGroupBytes: phys * 55 / 100, now: t0)
        #expect(w.isRed)
        let later = t0.addingTimeInterval(200)
        #expect(w.needsBreakdown(system: sys(usedPercent: 45), pressure: .normal, now: later))
        w.update(system: sys(usedPercent: 45), pressure: .normal, topGroupBytes: phys * 44 / 100, now: later)
        #expect(w.isRed)
    }

    @Test func frequentUpdatesDoNotEvictTheJumpBaseline() {
        var w = MemoryWatch()
        w.update(system: sys(usedPercent: 70), pressure: .normal, topGroupBytes: nil, now: t0)
        for i in 1...10 {
            w.update(system: sys(usedPercent: 80), pressure: .normal, topGroupBytes: nil, now: t0.addingTimeInterval(Double(i)))
        }
        #expect(!w.isRed)
        // 20 points above the baseline and ending at 90%, but only 10 above the fillers.
        w.update(system: sys(usedPercent: 90), pressure: .normal, topGroupBytes: nil, now: t0.addingTimeInterval(100))
        #expect(w.isRed)
    }

    @Test func backwardsClockStillClears() {
        var w = MemoryWatch()
        w.update(system: sys(usedPercent: 20), pressure: .critical, topGroupBytes: nil, now: t0.addingTimeInterval(1000))
        w.update(system: sys(usedPercent: 20), pressure: .normal, topGroupBytes: nil, now: t0)
        #expect(w.isRed)
        w.update(system: sys(usedPercent: 20), pressure: .normal, topGroupBytes: nil, now: t0.addingTimeInterval(61))
        #expect(!w.isRed)
    }

    @Test func zeroPhysicalIsNeverRed() {
        var w = MemoryWatch()
        w.update(system: SystemMemory(physical: 0, used: 100, swapUsed: 0), pressure: .normal, topGroupBytes: 100, now: t0)
        #expect(!w.isRed)
    }

    @Test func totalsWindowStaysBounded() {
        var w = MemoryWatch()
        for i in 0..<1000 {
            w.update(system: sys(usedPercent: 30), pressure: .normal, topGroupBytes: nil, now: t0.addingTimeInterval(Double(i) * 20))
        }
        #expect(w.storedTotalsCount == 5)
    }
}

@Suite struct CulpritsTests {
    @Test func culpritsNeedAFifteenPercentShare() {
        let groups = [group("a", percent: 40), group("b", percent: 30), group("c", percent: 20),
                      group("d", percent: 16), group("e", percent: 14)]
        let result = culprits(groups, physical: phys, previous: [:], now: t0)
        #expect(result.map(\.group.id) == ["a", "b", "c"])
        #expect(result.map(\.share) == [40, 30, 20])
        let few = culprits([group("a", percent: 40), group("e", percent: 14)], physical: phys, previous: [:], now: t0)
        #expect(few.map(\.group.id) == ["a"])
    }

    @Test func nothingStandsOut() {
        let groups = (0..<10).map { group("g\($0)", percent: 9) }
        #expect(culprits(groups, physical: phys, previous: [:], now: t0).isEmpty)
        #expect(culprits(groups, physical: 0, previous: [:], now: t0).isEmpty)
    }

    @Test func noGrowthWithoutAnEarlierReading() {
        let r = culprits([group("a", percent: 40)], physical: phys, previous: [:], now: t0)
        #expect(r.first?.growth == nil)
        #expect(r.first?.growthSeconds == nil)
    }

    @Test func growthOnlyWhenItGrew() {
        let g = group("a", percent: 40)
        let earlier = GroupReading(bytes: g.bytes - 2 * gb, at: t0.addingTimeInterval(-90))
        let grew = culprits([g], physical: phys, previous: ["a": earlier], now: t0)
        #expect(grew.first?.growth == 2 * gb)
        #expect(grew.first?.growthSeconds == 90)
        let bigger = GroupReading(bytes: g.bytes + gb, at: t0.addingTimeInterval(-90))
        let shrank = culprits([g], physical: phys, previous: ["a": bigger], now: t0)
        #expect(shrank.first?.growth == nil)
        #expect(shrank.first?.growthSeconds == nil)
        let tiny = GroupReading(bytes: g.bytes - gb / 2, at: t0.addingTimeInterval(-90))
        #expect(culprits([g], physical: phys, previous: ["a": tiny], now: t0).first?.growth == nil)
    }
}

@Suite struct MenuBarSymbolTests {
    @Test func memoryRedWinsOverLowSpace() {
        #expect(menuBarSymbol(memoryRed: true, lowSpace: true) == "memorychip.fill")
        #expect(menuBarSymbol(memoryRed: true, lowSpace: false) == "memorychip.fill")
    }

    @Test func otherwiseTheDiskSymbols() {
        #expect(menuBarSymbol(memoryRed: false, lowSpace: true) == "scalemass.fill")
        #expect(menuBarSymbol(memoryRed: false, lowSpace: false) == "scalemass")
    }
}

private func culprit(_ name: String, count: Int, bytes: Int64, share: Int, growth: Int64? = nil, seconds: Int? = nil) -> Culprit {
    let procs = (0..<count).map { ProcessSample(pid: Int32($0 + 10), startSeconds: 1, uid: 501, path: "/x", args: [], cwd: nil, footprint: 1) }
    return Culprit(group: MemoryGroup(id: name, name: name, processes: procs, bytes: bytes), share: share, growth: growth, growthSeconds: seconds)
}

@Suite struct CulpritLineTests {
    @Test func singleProcessOmitsCount() {
        #expect(culpritLine(culprit("Brave Browser", count: 1, bytes: 22 * gb, share: 69)) == "Brave Browser · \(formatBytes(22 * gb)) · 69% of memory")
    }

    @Test func groupShowsCountAndGrowth() {
        let c = culprit("vitest", count: 8, bytes: 31 * gb, share: 31, growth: 24 * gb, seconds: 120)
        #expect(culpritLine(c) == "vitest · 8 processes · \(formatBytes(31 * gb)) · 31% of memory · up \(formatBytes(24 * gb)) in 2 min")
    }

    @Test func growthDurationUnits() {
        func tail(_ s: Int) -> String { culpritLine(culprit("a", count: 1, bytes: 5 * gb, share: 30, growth: 2 * gb, seconds: s)) }
        #expect(tail(45).hasSuffix("in 45 s"))
        #expect(tail(119).hasSuffix("in 119 s"))
        #expect(tail(120).hasSuffix("in 2 min"))
        #expect(tail(150).hasSuffix("in 2 min"))
        #expect(tail(3 * 3600 + 100).hasSuffix("in 3 hr"))
    }

    @Test func noGrowthMeansNoUpPart() {
        #expect(!culpritLine(culprit("a", count: 2, bytes: 5 * gb, share: 30)).contains("up"))
    }
}
