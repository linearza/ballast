import Foundation

/// Big files in your personal folders. Only searched when you ask.
public struct LargeFilesProvider: Provider {
    public init(minBytes: Int64 = 500_000_000, inICloud: @escaping @Sendable (URL) -> Bool = Self.isUbiquitous) {
        self.minBytes = minBytes
        self.inICloud = inICloud
    }
    public let id = "largeFiles"
    public let title = "Large files"
    public let section = Section.personal
    public let symbol = "doc"
    public var needsUserStart: Bool { true }
    let minBytes: Int64
    let inICloud: @Sendable (URL) -> Bool

    /// Desktop and Documents can be synced with iCloud Drive without their path changing.
    public static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    static let folders = ["Documents", "Downloads", "Desktop", "Movies"]

    public func isPresent(_ env: Environment) async -> Bool { true }

    public func scan(_ env: Environment, pins: Pins) async -> [Item] { search(env) }

    func search(_ env: Environment) -> [Item] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        var items: [Item] = []
        for folder in Self.folders {
            guard let e = FileManager.default.enumerator(at: env.path(folder), includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let bytes = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                guard bytes >= minBytes else { continue }
                items.append(Item(id: "large.\(url.path)", title: url.lastPathComponent,
                                  detail: url.deletingLastPathComponent().path.replacingOccurrences(of: env.home.path, with: "~"),
                                  paths: [url], bytes: bytes, risk: .yourData, badges: inICloud(url) ? [.inICloud] : []))
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        var plan = planEach(ids, items: items, noun: "file") { item in
            [Step("Move \(item.title) to the Trash", .trash(item.paths), bytes: item.bytes, itemID: item.id)]
        }
        let synced = items.filter { ids.contains($0.id) && $0.badges.contains(.inICloud) }.map(\.title)
        if !synced.isEmpty {
            plan.dangers.append("\(synced.joined(separator: ", ")) \(synced.count == 1 ? "is" : "are") in iCloud Drive. Moving \(synced.count == 1 ? "it" : "them") to the Trash removes \(synced.count == 1 ? "it" : "them") from every device signed in to your iCloud account.")
        }
        return plan
    }
}
