import Testing
@testable import BallastCore

@Suite struct SingleInstanceTests {
    @Test func nothingElseRunningProceeds() {
        #expect(SingleInstance.decide(ours: "0.5.1", others: []) == .proceed)
    }

    @Test func sameVersionDefers() {
        #expect(SingleInstance.decide(ours: "0.5.1", others: ["0.5.1"]) == .deferToRunning)
    }

    @Test func newerRunningDefers() {
        #expect(SingleInstance.decide(ours: "0.5.1", others: ["0.6.0"]) == .deferToRunning)
        #expect(SingleInstance.decide(ours: "0.5.9", others: ["0.5.10"]) == .deferToRunning)
    }

    @Test func olderRunningIsReplaced() {
        #expect(SingleInstance.decide(ours: "0.5.1", others: ["0.5.0"]) == .replaceRunning)
        #expect(SingleInstance.decide(ours: "0.5.10", others: ["0.5.9"]) == .replaceRunning)
        #expect(SingleInstance.decide(ours: "1.0", others: ["0.9.9"]) == .replaceRunning)
    }

    @Test func missingTrailingPartsCountAsZero() {
        #expect(SingleInstance.decide(ours: "1.0", others: ["1.0.0"]) == .deferToRunning)
    }

    @Test func malformedOrMissingVersionsDefer() {
        #expect(SingleInstance.decide(ours: "0.5.1", others: [nil]) == .deferToRunning)
        #expect(SingleInstance.decide(ours: "0.5.1", others: [""]) == .deferToRunning)
        #expect(SingleInstance.decide(ours: "0.5.1", others: ["abc"]) == .deferToRunning)
        #expect(SingleInstance.decide(ours: "0.5.1", others: ["0.5.1-beta"]) == .deferToRunning)
        #expect(SingleInstance.decide(ours: nil, others: ["0.5.0"]) == .deferToRunning)
        #expect(SingleInstance.decide(ours: "x", others: ["0.5.0"]) == .deferToRunning)
    }

    @Test func multipleInstances() {
        #expect(SingleInstance.decide(ours: "0.5.1", others: ["0.4.0", "0.5.0"]) == .replaceRunning)
        #expect(SingleInstance.decide(ours: "0.5.1", others: ["0.4.0", "0.5.1"]) == .deferToRunning)
        #expect(SingleInstance.decide(ours: "0.5.1", others: ["0.4.0", "0.9.0"]) == .deferToRunning)
        #expect(SingleInstance.decide(ours: "0.5.1", others: ["0.4.0", nil]) == .deferToRunning)
    }
}
