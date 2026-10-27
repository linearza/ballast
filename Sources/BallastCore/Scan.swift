import Foundation

/// What the menu bar shows before a scan finishes: the last full scan, kept on disk.
public struct Summary: Codable, Sendable, Equatable {
    public var scannedAt: Date
    public var freeBytes: Int64
    public var totalBytes: Int64
    public var concerns: [Entry]

    public struct Entry: Codable, Sendable, Equatable {
        public var id, title, symbol: String
        public var bytes, reclaimable: Int64
    }
}

/// Runs providers and keeps the summary on disk. Reports belong to the caller.
public actor DiskScanner {
    let env: Environment
    let providers: [any Provider]
    let summaryURL: URL
    static let concurrency = 3

    public init(env: Environment, providers: [any Provider] = Providers.all, summaryURL: URL) {
        self.env = env
        self.providers = providers
        self.summaryURL = summaryURL
    }

    /// Scans every provider, or just `only`. Providers that need the user to start
    /// them run only when named in `only`. Locked folders are never measured here.
    public func scan(background: Bool, only: Set<String>? = nil) async -> [ConcernReport] {
        let chosen = providers.filter { p in
            if let only { return only.contains(p.id) }
            return !p.needsUserStart
        }
        let env = env
        let pins = scanPins(roots: env.projectRoots)
        let priority: TaskPriority = background ? .background : .userInitiated

        var reports: [Int: ConcernReport] = [:]
        await withTaskGroup(of: (Int, ConcernReport?).self) { group in
            var next = 0
            func add() {
                guard next < chosen.count else { return }
                let i = next, p = chosen[i]
                next += 1
                group.addTask(priority: priority) {
                    guard await p.isPresent(env) else { return (i, nil) }
                    let items = await p.scan(env, pins: pins)
                    return (i, ConcernReport(id: p.id, title: p.title, section: p.section, symbol: p.symbol, items: items, scannedAt: env.now()))
                }
            }
            for _ in 0..<Self.concurrency { add() }
            for await (i, report) in group {
                if let report { reports[i] = report }
                add()
            }
        }
        let ordered = reports.sorted { $0.key < $1.key }.map(\.value)
        if only == nil { writeSummary(ordered) }
        return ordered
    }

    func writeSummary(_ reports: [ConcernReport]) {
        let space = freeSpace()
        let summary = Summary(
            scannedAt: env.now(), freeBytes: space.free, totalBytes: space.total,
            concerns: reports.filter { !$0.items.isEmpty }
                .map { Summary.Entry(id: $0.id, title: $0.title, symbol: $0.symbol, bytes: $0.total, reclaimable: $0.reclaimable) }
                .sorted { $0.bytes > $1.bytes })
        guard let data = try? JSONEncoder().encode(summary) else { return }
        try? FileManager.default.createDirectory(at: summaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: summaryURL, options: .atomic)
    }

    public func lastSummary() -> Summary? {
        guard let data = try? Data(contentsOf: summaryURL) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }

    /// Free space as Finder counts it (including purgeable space) on the home folder's volume.
    public func freeSpace() -> (free: Int64, total: Int64) {
        let v = try? env.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
    }
}
