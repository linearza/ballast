import Testing
@testable import BallastCore

@Suite struct IPhoneWatchTests {
    @Test func iPhoneByName() {
        #expect(IPhoneWatch.isIOSDevice(vendorID: 0x05AC, productID: 0x12A8, productName: "iPhone"))
        #expect(IPhoneWatch.isIOSDevice(vendorID: 0x05AC, productID: nil, productName: "iPad"))
        #expect(IPhoneWatch.isIOSDevice(vendorID: 0x05AC, productID: nil, productName: "iPod touch"))
    }

    @Test func otherAppleGearIsNotIOS() {
        #expect(!IPhoneWatch.isIOSDevice(vendorID: 0x05AC, productID: 0x029C, productName: "Magic Keyboard"))
        #expect(!IPhoneWatch.isIOSDevice(vendorID: 0x05AC, productID: 0x1112, productName: nil))
    }

    @Test func nameBeatsProductID() {
        // A name that says it isn't an iPhone wins over an ID that happens to be in range.
        #expect(!IPhoneWatch.isIOSDevice(vendorID: 0x05AC, productID: 0x12A8, productName: "Apple Thing"))
    }

    @Test func productIDIsTheFallbackWhenNoName() {
        #expect(IPhoneWatch.isIOSDevice(vendorID: 0x05AC, productID: 0x12A8, productName: nil))
        #expect(IPhoneWatch.isIOSDevice(vendorID: 0x05AC, productID: 0x12A8, productName: ""))
        #expect(!IPhoneWatch.isIOSDevice(vendorID: 0x05AC, productID: nil, productName: nil))
    }

    @Test func otherVendorIsNeverIOS() {
        #expect(!IPhoneWatch.isIOSDevice(vendorID: 0x18D1, productID: 0x12A8, productName: "iPhone"))
    }

    @Test func burstOfAttachesIsOneRescan() {
        var q = IPhoneRescanQueue()
        q.request(); q.request(); q.request()
        let ran1 = q.take(scanning: false)
        #expect(ran1)
        let ran2 = q.take(scanning: false)
        #expect(!ran2)
    }

    @Test func rescanWaitsForARunningScan() {
        var q = IPhoneRescanQueue()
        q.request()
        let ran3 = q.take(scanning: true)
        #expect(!ran3)
        #expect(q.wanted)
        let ran4 = q.take(scanning: false)
        #expect(ran4)
    }

    @Test func nothingWantedMeansNothingStarts() {
        var q = IPhoneRescanQueue()
        let ran5 = q.take(scanning: false)
        #expect(!ran5)
        q.request(); q.cancel()
        let ran6 = q.take(scanning: false)
        #expect(!ran6)
    }

    @Test func lockedRetriesAtTenThenThirtySecondsThenStop() {
        #expect(IPhoneWatch.lockedRetryDelay(afterAttempt: 1) == 10)
        #expect(IPhoneWatch.lockedRetryDelay(afterAttempt: 2) == 30)
        #expect(IPhoneWatch.lockedRetryDelay(afterAttempt: 3) == nil)
        #expect(IPhoneWatch.lockedRetryDelay(afterAttempt: 0) == nil)
    }
}
