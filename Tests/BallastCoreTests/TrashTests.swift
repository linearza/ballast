import Foundation
import Testing
@testable import BallastCore

@Suite struct TrashTests {
    @Test func emptyFolderIsEmptyEvenThoughTheFolderItselfTakesSpace() async {
        let f = Fixture()
        f.dir("t")
        f.file("t/.DS_Store", bytes: 6148)
        let state = await trashState(at: f.url("t")) { Issue.record("Finder shouldn't be asked"); return nil }
        #expect(state == .empty)
    }

    @Test func readableTrashReportsItsSize() async {
        let f = Fixture()
        f.file("t/a.bin", bytes: 8192)
        let state = await trashState(at: f.url("t")) { nil }
        guard case .full(let bytes, let items) = state else { Issue.record("expected .full, got \(state)"); return }
        #expect(items == 1)
        #expect((bytes ?? 0) >= 8192)
    }

    @Test func unreadableTrashAsksFinderAndSaysEmpty() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t")) { FinderTrash(items: 0, bytes: 0) }
        #expect(state == .empty)
    }

    @Test func unreadableTrashAsksFinderForSize() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t")) { FinderTrash(items: 3, bytes: 5_000_000) }
        #expect(state == .full(bytes: 5_000_000, items: 3))
    }

    @Test func unreadableTrashWithOnlyAnItemCountStaysHonestAboutSize() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t")) { FinderTrash(items: 2, bytes: nil) }
        #expect(state == .full(bytes: nil, items: 2))
    }

    @Test func unreadableTrashWithNoAnswerIsUnknownNotZero() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t")) { nil }
        #expect(state == .unknown)
    }

    @Test func aFailureOnAnAlreadyEmptyTrashIsNotReported() {
        #expect(TrashState.empty.shouldReportFailure == false)
        #expect(TrashState.unknown.shouldReportFailure)
        #expect(TrashState.full(bytes: 1, items: 1).shouldReportFailure)
    }

    @Test func parsesFinderReply() {
        #expect(FinderTrash.parse("3, 5000000") == FinderTrash(items: 3, bytes: 5_000_000))
        #expect(FinderTrash.parse("0, 0") == FinderTrash(items: 0, bytes: 0))
        #expect(FinderTrash.parse("4, missing value") == FinderTrash(items: 4, bytes: nil))
        #expect(FinderTrash.parse("nonsense") == nil)
    }
}
