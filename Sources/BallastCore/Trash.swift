import Foundation

/// What the Trash holds, as far as Ballast can tell.
public enum TrashState: Sendable, Equatable {
    case empty
    /// `bytes` is nil when the items are known but their size isn't.
    case full(bytes: Int64?, items: Int?)
    /// Neither the folder nor Finder would say. Never shown as 0.
    case unknown

    /// Emptying something that is already empty isn't worth an alert.
    public var shouldReportFailure: Bool { self != .empty }
}

/// What Finder says about the Trash. It can read the Trash without Full Disk Access.
public struct FinderTrash: Sendable, Equatable {
    public var items: Int
    public var bytes: Int64?

    public init(items: Int, bytes: Int64?) {
        self.items = items
        self.bytes = bytes
    }

    /// The AppleScript reply "count, size" — the size is "missing value" when Finder won't give one.
    public static func parse(_ reply: String) -> FinderTrash? {
        let parts = reply.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let items = Int(parts[0]), items >= 0 else { return nil }
        return FinderTrash(items: items, bytes: Int64(parts[1]).flatMap { $0 >= 0 ? $0 : nil })
    }
}

/// Why the Trash is being looked at.
public enum TrashRefresh: Sendable {
    /// Launch or a scan: must never make macOS show an Automation prompt.
    case passive
    /// The user clicked Empty, so a prompt is expected.
    case clicked
}

/// Whether Finder may be asked about the Trash. A passive look only asks when the permission is already granted.
public func mayAskFinder(_ reason: TrashRefresh, granted: Bool) -> Bool {
    reason == .clicked || granted
}

/// Reads the Trash folder; when macOS won't let us, asks `finder` instead (only then, and only if `mayAskFinder`).
/// `finderGranted` is called only for a passive look.
public func trashState(at folder: URL, reason: TrashRefresh, finderGranted: @Sendable () -> Bool,
                       finder: @Sendable () async -> FinderTrash?) async -> TrashState {
    if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
        // Finder hides .DS_Store, so an otherwise empty Trash with one is still empty.
        let items = names.filter { $0 != ".DS_Store" }
        if items.isEmpty { return .empty }
        return .full(bytes: await measure([folder]).bytes, items: items.count)
    }
    guard mayAskFinder(reason, granted: reason == .clicked || finderGranted()) else { return .unknown }
    guard let found = await finder() else { return .unknown }
    return found.items == 0 ? .empty : .full(bytes: found.bytes, items: found.items)
}
