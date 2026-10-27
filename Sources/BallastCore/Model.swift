import Foundation

public enum BallastCore {
    public static let version = "0.1.0"
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

    public var meansInUse: Bool {
        switch self {
        case .isDefault, .pinned, .running, .uncommitted, .unpushed, .openPR, .selectedByXcodeSelect: true
        case .mergedPR, .orphaned, .lastUsed, .locked: false
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
    public var warnings: [String]
    public var refusals: [Refusal]

    public init(steps: [Step] = [], warnings: [String] = [], refusals: [Refusal] = []) {
        self.steps = steps
        self.warnings = warnings
        self.refusals = refusals
    }

    public var expectedBytes: Int64 { steps.reduce(0) { $0 + $1.expectedBytes } }

    public mutating func append(_ other: Plan) {
        steps += other.steps
        warnings += other.warnings
        refusals += other.refusals
    }
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
