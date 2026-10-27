import Foundation
import Testing
@testable import BallastCore

@Suite struct MeasureTests {
    @Test func countsAllocatedBytes() async {
        let f = Fixture()
        f.file("a/b.bin", bytes: 8192)
        let m = await measure([f.url("a")])
        #expect(m.bytes >= 8192)
        #expect(!m.partial)
    }

    @Test func countsHardLinksOnce() async {
        let f = Fixture()
        f.file("a/b.bin", bytes: 1_000_000)
        let alone = await measure([f.url("a/b.bin")])
        f.hardlink("a/h.bin", to: "a/b.bin")
        let both = await measure([f.url("a/b.bin"), f.url("a/h.bin")])
        #expect(both.bytes == alone.bytes)
    }

    @Test func skipsSymlinks() async {
        let f = Fixture()
        f.file("big/x.bin", bytes: 1_000_000)
        f.link("w/l", to: "big")
        let m = await measure([f.url("w")])
        #expect(m.bytes < 4096 + 4096)
        #expect(m.bytes < 1_000_000)
    }

    @Test func sparseFileUsesAllocated() async throws {
        let f = Fixture()
        let u = f.file("sparse.bin", bytes: 4096)
        let h = try FileHandle(forWritingTo: u)
        try h.truncate(atOffset: 100_000_000)
        try h.close()
        let m = await measure([u])
        #expect(m.bytes < 1_000_000)
    }

    @Test func unreadableIsPartial() async {
        let f = Fixture()
        f.file("t/ok.bin", bytes: 8192)
        f.unreadable("t/secret")
        let m = await measure([f.url("t")])
        #expect(m.partial)
        #expect(m.bytes > 0)
    }

    @Test func missingPathIsZero() async {
        let f = Fixture()
        let m = await measure([f.url("nope")])
        #expect(m.bytes == 0)
        #expect(!m.partial)
    }

    @Test func badgesInUse() {
        var item = Item(id: "x", title: "X", paths: [], bytes: 0, risk: .regenerable, badges: [.pinned(by: ["pipe"])])
        #expect(item.inUse)
        item.badges = [.orphaned]
        #expect(!item.inUse)
        item.badges = [.lastUsed(Date())]
        #expect(!item.inUse)
    }

    @Test func reportTotals() {
        let a = Item(id: "a", title: "A", paths: [], bytes: 100, risk: .regenerable, badges: [])
        let b = Item(id: "b", title: "B", paths: [], bytes: 50, risk: .regenerable, badges: [.isDefault])
        let c = Item(id: "c", title: "C", paths: [], bytes: 25, risk: .review, badges: [])
        let r = ConcernReport(id: "r", title: "R", section: .toolchains, symbol: "x", items: [a, b, c], scannedAt: Date())
        #expect(r.total == 175)
        #expect(r.reclaimable == 100)
    }

    @Test func riskLabels() {
        #expect(Risk.regenerable.label == "Regenerable")
        #expect(Risk.review.label == "Review")
        #expect(Risk.yourData.label == "Your data")
    }

    @Test func selectSafePicksRegenerableUnused() {
        let items = [
            Item(id: "a", title: "a", paths: [], bytes: 1, risk: .regenerable),
            Item(id: "b", title: "b", paths: [], bytes: 1, risk: .regenerable, badges: [.running]),
            Item(id: "c", title: "c", paths: [], bytes: 1, risk: .review),
            Item(id: "d", title: "d", paths: [], bytes: 1, risk: .yourData),
            Item(id: "e", title: "e", paths: [], bytes: 1, risk: .regenerable, badges: [.mergedPR]),
        ]
        #expect(selectSafe(items) == ["a", "e"])
    }

    @Test func removeLabels() {
        #expect(removeLabel(count: 1, bytes: 1_000_000_000) == "Remove 1 item · 1 GB")
        #expect(removeLabel(count: 9, bytes: 6_300_000_000) == "Remove 9 items · \(formatBytes(6_300_000_000))")
        #expect(formatBytes(6_300_000_000).hasPrefix("6"))
    }
}
