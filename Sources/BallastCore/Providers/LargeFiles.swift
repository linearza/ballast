import Foundation

/// Big files in your personal folders. Only searched when you ask.
public struct LargeFilesProvider: Provider {
    public init(minBytes: Int64 = 500_000_000) { self.minBytes = minBytes }
    public let id = "largeFiles"
    public let title = "Large files"
    public let section = Section.personal
    public let symbol = "doc"
    public var needsUserStart: Bool { true }
    let minBytes: Int64

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
                                  paths: [url], bytes: bytes, risk: .yourData))
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    public func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan {
        planEach(ids, items: items, noun: "file") { item in
            [Step("Move \(item.title) to the Trash", .trash(item.paths), bytes: item.bytes, itemID: item.id)]
        }
    }
}
