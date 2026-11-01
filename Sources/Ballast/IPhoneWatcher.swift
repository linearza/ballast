import BallastCore
import Foundation
import IOKit

/// Notices an iPhone, iPad or iPod being plugged in or unplugged, so the menu doesn't wait for the next scan.
/// It only reports; what to do about it is the model's business.
@MainActor final class IPhoneWatcher {
    private let onAttach: @MainActor () -> Void
    private let onDetach: @MainActor () -> Void
    private var port: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var detachIterator: io_iterator_t = 0
    /// Registry IDs of the iOS devices we know are plugged in. A device that is going away can't always be asked
    /// for its name, so unplugging is recognised by ID instead.
    private var present: Set<UInt64> = []

    init(onAttach: @escaping @MainActor () -> Void, onDetach: @escaping @MainActor () -> Void) {
        self.onAttach = onAttach
        self.onDetach = onDetach
    }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Each registration consumes its own matching dictionary, so build one per call.
        func matching() -> CFMutableDictionary {
            let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            // Properties go under IOPropertyMatch; a bare top-level key silently matches nothing.
            dict["IOPropertyMatch"] = ["idVendor": IPhoneWatch.appleVendorID]
            return dict as CFMutableDictionary
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching(), { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<IPhoneWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.attached(iterator, announce: true) }
        }, refcon, &attachIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching(), { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<IPhoneWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.detached(iterator) }
        }, refcon, &detachIterator)
        // Draining arms the notification. Phones already plugged in are remembered but not announced:
        // the launch scan covers them.
        attached(attachIterator, announce: false)
        detached(detachIterator)
    }

    private func attached(_ iterator: io_iterator_t, announce: Bool) {
        var found = false
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard Self.isIOS(device), let id = Self.registryID(device) else { continue }
            present.insert(id)
            found = true
        }
        if found && announce { onAttach() }
    }

    private func detached(_ iterator: io_iterator_t) {
        var gone = false
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            if let id = Self.registryID(device), present.remove(id) != nil { gone = true }
        }
        if gone && present.isEmpty { onDetach() }
    }

    private static func registryID(_ device: io_object_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(device, &id) == KERN_SUCCESS ? id : nil
    }

    private static func isIOS(_ device: io_object_t) -> Bool {
        func prop(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        return IPhoneWatch.isIOSDevice(vendorID: (prop("idVendor") as? Int) ?? 0,
                                       productID: prop("idProduct") as? Int,
                                       productName: prop("USB Product Name") as? String)
    }
}
