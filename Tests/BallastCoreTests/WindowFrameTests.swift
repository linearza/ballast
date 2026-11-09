import Foundation
import Testing

@testable import BallastCore

struct WindowFrameTests {
    let old = CGRect(x: 100, y: 500, width: 320, height: 600)  // maxY 1100

    @Test func shrinkingKeepsTheTopEdge() throws {
        let new = try #require(topAnchoredFrame(old, contentHeight: 400))
        #expect(new.height == 400)
        #expect(new.maxY == old.maxY)
        #expect(new.origin.x == old.origin.x && new.width == old.width)
    }

    @Test func growingKeepsTheTopEdge() throws {
        let new = try #require(topAnchoredFrame(old, contentHeight: 700))
        #expect(new.height == 700)
        #expect(new.maxY == old.maxY)
        #expect(new.origin.y == 400)
    }

    @Test func noChangeAndSubPointChangesAreIgnored() {
        #expect(topAnchoredFrame(old, contentHeight: 600) == nil)
        #expect(topAnchoredFrame(old, contentHeight: 600.5) == nil)
        #expect(topAnchoredFrame(old, contentHeight: 0) == nil)
    }
}
