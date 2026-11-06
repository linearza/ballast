import Foundation
import Testing
@testable import BallastCore

@Suite struct TrashTests {
    @Test func emptyFolderIsEmptyEvenThoughTheFolderItselfTakesSpace() async {
        let f = Fixture()
        f.dir("t")
        f.file("t/.DS_Store", bytes: 6148)
        let state = await trashState(at: f.url("t"), reason: .clicked, finderGranted: { false }) { Issue.record("Finder shouldn't be asked"); return nil }
        #expect(state == .empty)
    }

    @Test func readableTrashReportsItsSize() async {
        let f = Fixture()
        f.file("t/a.bin", bytes: 8192)
        let state = await trashState(at: f.url("t"), reason: .clicked, finderGranted: { false }) { nil }
        guard case .full(let bytes, let items) = state else { Issue.record("expected .full, got \(state)"); return }
        #expect(items == 1)
        #expect((bytes ?? 0) >= 8192)
    }

    @Test func unreadableTrashAsksFinderAndSaysEmpty() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t"), reason: .clicked, finderGranted: { false }) { FinderTrash(items: 0, bytes: 0) }
        #expect(state == .empty)
    }

    @Test func unreadableTrashAsksFinderForSize() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t"), reason: .clicked, finderGranted: { false }) { FinderTrash(items: 3, bytes: 5_000_000) }
        #expect(state == .full(bytes: 5_000_000, items: 3))
    }

    @Test func unreadableTrashWithOnlyAnItemCountStaysHonestAboutSize() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t"), reason: .clicked, finderGranted: { false }) { FinderTrash(items: 2, bytes: nil) }
        #expect(state == .full(bytes: nil, items: 2))
    }

    @Test func unreadableTrashWithNoAnswerIsUnknownNotZero() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t"), reason: .clicked, finderGranted: { false }) { nil }
        #expect(state == .unknown)
    }

    @Test func passiveLookWithoutPermissionNeverAsksFinder() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t"), reason: .passive, finderGranted: { false }) {
            Issue.record("Finder must not be asked"); return FinderTrash(items: 1, bytes: 1)
        }
        #expect(state == .unknown)
    }

    @Test func passiveLookWithPermissionAsksFinder() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t"), reason: .passive, finderGranted: { true }) { FinderTrash(items: 1, bytes: 9) }
        #expect(state == .full(bytes: 9, items: 1))
    }

    @Test func clickedLookAsksFinderEvenWithoutPermission() async {
        let f = Fixture()
        f.unreadable("t")
        let state = await trashState(at: f.url("t"), reason: .clicked, finderGranted: { false }) { FinderTrash(items: 1, bytes: 9) }
        #expect(state == .full(bytes: 9, items: 1))
        #expect(mayAskFinder(.clicked, granted: false))
        #expect(mayAskFinder(.passive, granted: true))
        #expect(!mayAskFinder(.passive, granted: false))
    }

    @Test func aFailureOnAnAlreadyEmptyTrashIsNotReported() {
        #expect(TrashState.empty.shouldReportFailure == false)
        #expect(TrashState.unknown.shouldReportFailure)
        #expect(TrashState.full(bytes: 1, items: 1).shouldReportFailure)
    }

    @Test func asksFinderThroughOsascriptAndParsesTheReply() async {
        let runner = FakeRunner(["/usr/bin/osascript -e \(FinderTrash.script)": FakeRunner.out("3, 5.0E+6\n")])
        #expect(await FinderTrash.ask(runner: runner) == FinderTrash(items: 3, bytes: 5_000_000))
    }

    @Test func finderRefusalTimeoutAndNonsenseGiveNil() async {
        let key = "/usr/bin/osascript -e \(FinderTrash.script)"
        let denied = CommandResult(status: 1, stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)")
        #expect(await FinderTrash.ask(runner: FakeRunner([key: denied])) == nil)
        #expect(await FinderTrash.ask(runner: FakeRunner([key: CommandResult(status: -1, stderr: "timed out after 12 s")])) == nil)
        #expect(await FinderTrash.ask(runner: FakeRunner([key: FakeRunner.out("")])) == nil)
    }

    @Test func parsesFinderReply() {
        #expect(FinderTrash.parse("3, 5000000") == FinderTrash(items: 3, bytes: 5_000_000))
        #expect(FinderTrash.parse("0, 0") == FinderTrash(items: 0, bytes: 0))
        #expect(FinderTrash.parse("4, missing value") == FinderTrash(items: 4, bytes: nil))
        #expect(FinderTrash.parse("nonsense") == nil)
    }
}
