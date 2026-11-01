import Foundation

/// The decisions behind noticing an iPhone being plugged in or unplugged. The IOKit plumbing lives in the app;
/// everything here is plain logic so it can be tested.
public enum IPhoneWatch {
    public static let appleVendorID = 0x05AC
    /// usbmuxd needs a moment to register a new device before the tools can see it.
    public static let settleDelay: TimeInterval = 2
    /// How long after a "locked" answer to look again (once at 10 s, once at 30 s), then stop.
    public static let lockedRetryDelays: [TimeInterval] = [10, 30]

    /// Whether a USB device is an iPhone, iPad or iPod. The product name is the main test, since it is
    /// what the device calls itself. The product ID range is the fallback for a device whose name can't be read
    /// (Apple's iOS devices in normal mode use 0x1290-0x12AF); it is checked second because Apple has added IDs over the years.
    /// Other Apple USB gear (keyboards, displays, the Mac's own hubs) is neither.
    public static func isIOSDevice(vendorID: Int, productID: Int?, productName: String?) -> Bool {
        guard vendorID == appleVendorID else { return false }
        if let name = productName?.lowercased(), !name.isEmpty {
            return ["iphone", "ipad", "ipod"].contains { name.contains($0) }
        }
        guard let productID else { return false }
        return (0x1290...0x12AF).contains(productID)
    }

    /// How long to wait before looking again after the `attempt`th (1-based) "locked" answer, or nil to give up.
    public static func lockedRetryDelay(afterAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= lockedRetryDelays.count else { return nil }
        return lockedRetryDelays[attempt - 1]
    }
}

/// Remembers that an iPhone rescan is wanted, so a burst of attach events (an iPhone often re-enumerates when
/// unlocked or when Trust is tapped) and a scan already running both end up as one rescan.
public struct IPhoneRescanQueue: Sendable, Equatable {
    public private(set) var wanted = false
    public init() {}

    /// An attach (or a retry) asks for a rescan. Any number of asks before `take` count once.
    public mutating func request() { wanted = true }

    /// Drops a wanted rescan, e.g. because the phone went away again.
    public mutating func cancel() { wanted = false }

    /// True when a rescan should start now. Nothing starts while a scan is running; the ask waits for the next call.
    public mutating func take(scanning: Bool) -> Bool {
        guard wanted, !scanning else { return false }
        wanted = false
        return true
    }
}
