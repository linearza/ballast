import Testing
import Foundation
@testable import BallastCore

private func sample(_ pid: Int32, uid: UInt32 = 501, path: String? = "/usr/local/bin/thing", start: UInt64 = 100) -> ProcessSample {
    ProcessSample(pid: pid, startSeconds: start, uid: uid, path: path, args: [], cwd: nil, footprint: 1000)
}

private func group(_ procs: [ProcessSample], id: String = "exe:/usr/local/bin/thing") -> MemoryGroup {
    MemoryGroup(id: id, name: "thing", processes: procs, bytes: procs.reduce(0) { $0 + $1.footprint })
}

private final class FakeControl: ProcessControl, @unchecked Sendable {
    var identities: [Int32: (startSeconds: UInt64, path: String?)]
    var sent: [(Int32, Int32)] = []
    init(_ identities: [Int32: (startSeconds: UInt64, path: String?)]) { self.identities = identities }
    func identity(pid: Int32) -> (startSeconds: UInt64, path: String?)? { identities[pid] }
    func signal(pid: Int32, _ sig: Int32) -> Bool { sent.append((pid, sig)); return true }
}

@Suite struct MemoryCloseTests {
    @Test func systemProcessNotOffered() {
        let g = group([sample(10, path: "/usr/libexec/thing")])
        guard case .notOffered = closeOption(for: g, myUID: 501, myPID: 1) else { Issue.record("expected notOffered"); return }
    }

    @Test func systemAppNotOffered() {
        let g = group([sample(10, path: "/System/Applications/Mail.app/Contents/MacOS/Mail")], id: "app:/System/Applications/Mail.app")
        guard case .notOffered = closeOption(for: g, myUID: 501, myPID: 1) else { Issue.record("expected notOffered"); return }
    }

    @Test func otherUsersNotOffered() {
        let g = group([sample(10, uid: 0), sample(11, uid: 0)])
        guard case .notOffered = closeOption(for: g, myUID: 501, myPID: 1) else { Issue.record("expected notOffered"); return }
    }

    @Test func otherUsersAppNotOffered() {
        let p = sample(10, uid: 0, path: "/Applications/X.app/Contents/MacOS/X")
        guard case .notOffered = closeOption(for: group([p], id: "app:/Applications/X.app"), myUID: 501, myPID: 1) else { Issue.record("expected notOffered"); return }
    }

    @Test func ballastNeverOffered() {
        let g = group([sample(10), sample(42)])
        guard case .notOffered = closeOption(for: g, myUID: 501, myPID: 42) else { Issue.record("expected notOffered"); return }
    }

    @Test func appGroupClosesAsApp() {
        let base = "/Applications/Brave Browser.app/Contents"
        let g = group([sample(10, path: "\(base)/MacOS/Brave Browser"),
                       sample(11, path: "\(base)/Frameworks/Helper.app/Contents/MacOS/Helper")],
                      id: "app:/Applications/Brave Browser.app")
        #expect(closeOption(for: g, myUID: 501, myPID: 1) == .app(bundlePath: "/Applications/Brave Browser.app", skipped: 0))
    }

    @Test func appGroupCountsOtherUsersSkipped() {
        let base = "/Applications/Brave Browser.app/Contents"
        let g = group([sample(10, path: "\(base)/MacOS/Brave Browser"), sample(11, uid: 0, path: "\(base)/MacOS/H")],
                      id: "app:/Applications/Brave Browser.app")
        #expect(closeOption(for: g, myUID: 501, myPID: 1) == .app(bundlePath: "/Applications/Brave Browser.app", skipped: 1))
    }

    @Test func mixedGroupClosesOnlyMine() {
        let mine = [sample(10), sample(11), sample(12)]
        let g = group(mine + [sample(13, uid: 0)])
        #expect(closeOption(for: g, myUID: 501, myPID: 1) == .processes(mine, skipped: 1))
    }

    @Test func nilPathProcessIsSkippedNotSignalled() {
        let mine = [sample(10), sample(11)]
        let g = group(mine + [sample(12, path: nil)])
        #expect(closeOption(for: g, myUID: 501, myPID: 1) == .processes(mine, skipped: 1))
    }

    @Test func allIneligibleNotOffered() {
        let g = group([sample(10, path: nil)])
        guard case .notOffered = closeOption(for: g, myUID: 501, myPID: 1) else { Issue.record("expected notOffered"); return }
    }

    @Test func matchingProcessIsSignalled() {
        let p = sample(10)
        let c = FakeControl([10: (100, p.path)])
        let out = signalAll([p], signal: SIGTERM, control: c)
        #expect(out == CloseOutcome(signalled: [10], refused: []))
        #expect(c.sent.count == 1 && c.sent[0] == (10, SIGTERM))
    }

    @Test func reusedPIDIsRefused() {
        let p = sample(10)
        let c = FakeControl([10: (999, p.path)])
        let out = signalAll([p], signal: SIGTERM, control: c)
        #expect(out == CloseOutcome(signalled: [], refused: [10]))
        #expect(c.sent.isEmpty)
    }

    @Test func pathMismatchWithSameStartIsRefused() {
        let p = sample(10)
        let c = FakeControl([10: (100, "/usr/local/bin/other")])
        let out = signalAll([p], signal: SIGTERM, control: c)
        #expect(out.refused == [10])
        #expect(c.sent.isEmpty)
    }

    @Test func nilCurrentPathIsRefused() {
        let p = sample(10)
        let c = FakeControl([10: (100, nil)])
        #expect(signalAll([p], signal: SIGTERM, control: c).refused == [10])
        #expect(c.sent.isEmpty)
    }

    @Test func goneProcessIsRefused() {
        let c = FakeControl([:])
        let out = signalAll([sample(10)], signal: SIGTERM, control: c)
        #expect(out == CloseOutcome(signalled: [], refused: [10]))
        #expect(c.sent.isEmpty)
    }

    @Test func lowPIDsAreRefused() {
        let ps = [sample(0), sample(1), sample(-5)]
        let c = FakeControl([0: (100, ps[0].path), 1: (100, ps[1].path), -5: (100, ps[2].path)])
        let out = signalAll(ps, signal: SIGTERM, control: c)
        #expect(out.signalled.isEmpty)
        #expect(out.refused == [0, 1, -5])
        #expect(c.sent.isEmpty)
    }

    @Test func survivorsListsTheStillRunning() {
        let a = sample(10), b = sample(11), reused = sample(12)
        let c = FakeControl([10: (100, a.path), 12: (555, reused.path)])
        #expect(survivors([a, b, reused], control: c) == [a])
    }
}
