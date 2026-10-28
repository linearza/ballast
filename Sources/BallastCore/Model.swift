import Foundation

public enum BallastCore {
    public static let version = "0.3.1"
}

/// How safe an item is to remove.
public enum Risk: String, Codable, Sendable, CaseIterable {
    case regenerable, review, yourData

    public var label: String {
        switch self {
        case .regenerable: "Regenerable"
        case .review: "Review"
        case .yourData: "Your data"
        }
    }
}

/// Facts about an item shown as capsules; some of them mean the item is in use.
public enum Badge: Hashable, Codable, Sendable {
    case isDefault
    case pinned(by: [String])
    case running
    case mergedPR
    case openPR
    case uncommitted(Int)
    case unpushed(Int)
    case orphaned
    case lastUsed(Date)
    case locked
    case selectedByXcodeSelect
    /// Synced with iCloud Drive, so removing it removes it on every device.
    case inICloud

    public var meansInUse: Bool {
        switch self {
        case .isDefault, .pinned, .running, .uncommitted, .unpushed, .openPR, .selectedByXcodeSelect: true
        case .mergedPR, .orphaned, .lastUsed, .locked, .inICloud: false
        }
    }
}

public struct Item: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    public var paths: [URL]
    public var bytes: Int64
    public var sizeIsPartial: Bool
    public var risk: Risk
    public var badges: Set<Badge>

    public init(id: String, title: String, detail: String? = nil, paths: [URL], bytes: Int64,
                sizeIsPartial: Bool = false, risk: Risk, badges: Set<Badge> = []) {
        self.id = id
        self.title = title
        self.detail = detail
        self.paths = paths
        self.bytes = bytes
        self.sizeIsPartial = sizeIsPartial
        self.risk = risk
        self.badges = badges
    }

    public var inUse: Bool { badges.contains { $0.meansInUse } }
    public var isLocked: Bool { badges.contains(.locked) }
}

public enum Section: String, CaseIterable, Codable, Sendable {
    case toolchains = "Developer toolchains"
    case containers = "Containers and VMs"
    case projects = "Project leftovers"
    case caches = "Caches"
    case databases = "Local databases"
    case ai = "AI models"
    case editors = "AI tools and editors"
    case apps = "Apps"
    case personal = "Large personal files"
    case other = "Other dev data"
}

public struct ConcernReport: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var section: Section
    public var symbol: String
    public var items: [Item]
    public var scannedAt: Date

    public init(id: String, title: String, section: Section, symbol: String, items: [Item], scannedAt: Date) {
        self.id = id
        self.title = title
        self.section = section
        self.symbol = symbol
        self.items = items
        self.scannedAt = scannedAt
    }

    public var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    /// What can go without a second thought: regenerable and not in use.
    public var reclaimable: Int64 {
        items.filter { $0.risk == .regenerable && !$0.inUse }.reduce(0) { $0 + $1.bytes }
    }
}

// MARK: - Plans

public enum StepKind: Sendable, Equatable {
    /// A tool's own command, run directly.
    case command(argv: [String])
    /// A tool's own command that needs its shell setup (rvm, nvm), run with `zsh -lc`.
    case shell(String)
    case trash([URL])
    /// Empties a file in place, for logs a running service still writes to.
    case truncate(URL)
    case unloadLoginItem(label: String, plist: URL)
    /// Needs administrator rights: shown with a Copy button, never run by Ballast.
    case copyToTerminal(String)

    /// What the confirmation sheet shows for this step.
    public var display: String {
        switch self {
        case .command(let argv): argv.map(shellQuote).joined(separator: " ")
        case .shell(let script): script
        case .trash(let urls): urls.map(\.path).joined(separator: "\n")
        case .truncate(let url): url.path
        case .unloadLoginItem(let label, let plist): "launchctl bootout gui/\(getuid())/\(label)\n\(plist.path)"
        case .copyToTerminal(let command): command
        }
    }

    /// Whether the step can be taken back, said next to it before anything runs.
    public var undo: Undo {
        switch self {
        case .trash, .unloadLoginItem: .fromTrash
        case .command, .shell, .truncate: .never
        case .copyToTerminal: .yourCall
        }
    }
}

public enum Undo: Sendable, Equatable {
    case fromTrash, never, yourCall

    public var label: String {
        switch self {
        case .fromTrash: "Can be put back from the Trash"
        case .never: "Deleted for good"
        case .yourCall: "Ballast won't run this. Only paste it into Terminal if you're sure; it asks for your password"
        }
    }
}

public struct Step: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var kind: StepKind
    public var expectedBytes: Int64
    public var itemID: String?

    public init(_ title: String, _ kind: StepKind, bytes: Int64 = 0, itemID: String? = nil) {
        self.id = UUID()
        self.title = title
        self.kind = kind
        self.expectedBytes = bytes
        self.itemID = itemID
    }
}

public struct Refusal: Sendable, Equatable {
    public var itemID: String
    public var reason: String

    public init(itemID: String, reason: String) {
        self.itemID = itemID
        self.reason = reason
    }
}

public struct Plan: Sendable {
    public var steps: [Step]
    /// Worth reading first.
    public var warnings: [String]
    /// Hard to recover from: the user has to say they understand before Remove is enabled.
    public var dangers: [String]
    public var refusals: [Refusal]

    public init(steps: [Step] = [], warnings: [String] = [], dangers: [String] = [], refusals: [Refusal] = []) {
        self.steps = steps
        self.warnings = warnings
        self.dangers = dangers
        self.refusals = refusals
    }

    public var expectedBytes: Int64 { steps.reduce(0) { $0 + $1.expectedBytes } }

    public mutating func append(_ other: Plan) {
        steps += other.steps
        warnings += other.warnings
        dangers += other.dangers
        refusals += other.refusals
    }
}

/// How much the confirmation asks of the user.
public enum Caution: Sendable, Equatable {
    /// Regenerable things nobody uses: Return confirms.
    case routine
    /// Worth a look: Remove needs a click.
    case careful
    /// Hard to recover from: Remove needs a click after ticking "I understand".
    case dangerous
}

/// The provider's dangers, plus one for each item of your data the provider didn't already explain.
public func dangerNotes(_ plan: Plan, items: [Item]) -> [String] {
    let planned = Set(plan.steps.compactMap(\.itemID))
    let unexplained = items.filter { planned.contains($0.id) && $0.risk == .yourData }
        .filter { item in !plan.dangers.contains { $0.contains(item.title) } }
        .map { "\($0.title) is your data. Only you can tell whether it's still needed, and Ballast can't bring it back." }
    return plan.dangers + unexplained
}

public func caution(of plan: Plan, items: [Item]) -> Caution {
    if !dangerNotes(plan, items: items).isEmpty { return .dangerous }
    let planned = Set(plan.steps.compactMap(\.itemID))
    if !plan.warnings.isEmpty || items.contains(where: { planned.contains($0.id) && $0.risk != .regenerable }) { return .careful }
    return .routine
}

/// "Safe to reclaim" across every concern: regenerable items nothing uses, biggest group first.
public func safeGroups(_ reports: [ConcernReport]) -> [(report: ConcernReport, items: [Item])] {
    reports.compactMap { r in
        let safe = selectSafe(r.items)
        let items = r.items.filter { safe.contains($0.id) }.sorted { $0.bytes > $1.bytes }
        return items.isEmpty ? nil : (r, items)
    }
    .sorted { $0.items.reduce(0) { $0 + $1.bytes } > $1.items.reduce(0) { $0 + $1.bytes } }
}

/// A whole-tool action offered beside the item list, like "Uninstall RVM completely".
/// Its id is passed to `Provider.plan` like an item id.
public struct ProviderAction: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var itemIDs: [String]

    public init(id: String, title: String, itemIDs: [String]) {
        self.id = id
        self.title = title
        self.itemIDs = itemIDs
    }
}

// MARK: - Selection

/// What "Select safe" picks: regenerable items that nothing uses and whose size is known.
public func selectSafe(_ items: [Item]) -> Set<String> {
    Set(items.filter { $0.risk == .regenerable && !$0.inUse && !$0.isLocked }.map(\.id))
}

/// "Remove 1 item · 1 GB", "Remove 9 items · 6.3 GB".
public func removeLabel(count: Int, bytes: Int64) -> String {
    "Remove \(count) \(count == 1 ? "item" : "items") · \(formatBytes(bytes))"
}

/// `Section` for SwiftUI files, where it clashes with SwiftUI.Section.
public typealias ConcernSection = Section

// MARK: - Versions

/// Compares dotted versions numerically, ignoring a leading `v`; missing parts count as 0.
public func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    func parts(_ s: String) -> [Int] {
        let t = s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
        return t.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l < r ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
}

/// A release page link from GitHub's API, kept only when it points at github.com over https.
public func releaseLink(_ s: String) -> URL? {
    guard let url = URL(string: s), url.scheme == "https", url.host == "github.com" else { return nil }
    return url
}
