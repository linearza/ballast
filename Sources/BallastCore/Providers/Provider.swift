import Foundation

/// One concern: finds its items, measures them, says what's in use, and
/// turns a selection into a plan the user reviews before anything runs.
public protocol Provider: Sendable {
    var id: String { get }
    var title: String { get }
    var section: Section { get }
    var symbol: String { get }
    /// Only scanned when the user asks (it reads folders macOS protects).
    var needsUserStart: Bool { get }

    func isPresent(_ env: Environment) async -> Bool
    func scan(_ env: Environment, pins: Pins) async -> [Item]
    func extraActions(_ items: [Item]) -> [ProviderAction]
    /// `ids` are item ids or extra action ids.
    func plan(_ ids: [String], items: [Item], env: Environment) async -> Plan
    /// Runs right before removal: a reason to skip this item now, or nil.
    func recheck(_ item: Item, env: Environment, pins: Pins) async -> Refusal?
}

extension Provider {
    public var needsUserStart: Bool { false }
    public func extraActions(_ items: [Item]) -> [ProviderAction] { [] }

    public func recheck(_ item: Item, env: Environment, pins: Pins) async -> Refusal? {
        guard let fresh = await scan(env, pins: pins).first(where: { $0.id == item.id }) else {
            return Refusal(itemID: item.id, reason: "Already gone")
        }
        guard fresh.inUse, !item.inUse else { return nil }
        return Refusal(itemID: item.id, reason: newlyInUseReason(fresh.badges.subtracting(item.badges), noun: title))
    }
}

public enum Providers {
    public static let all: [any Provider] = [
        RubyProvider(), NodeProvider(), PythonProvider(), HomebrewProvider(), DatabasesProvider(), LoginItemsProvider(),
    ]
}

// MARK: - Helpers shared by providers

func newlyInUseReason(_ badges: Set<Badge>, noun: String) -> String {
    for badge in badges {
        switch badge {
        case .isDefault: return "Now the default \(noun)"
        case .pinned(let by): return "Now pinned by \(by.joined(separator: ", "))"
        case .running: return "Now running"
        case .uncommitted: return "Has uncommitted changes"
        case .unpushed: return "Has commits that aren't pushed"
        case .openPR: return "Has an open pull request"
        case .selectedByXcodeSelect: return "Your developer tools point at this Xcode"
        default: continue
        }
    }
    return "Now in use"
}

/// Why removing an in-use item deserves a second look.
func inUseWarning(_ item: Item, noun: String) -> String? {
    var reasons: [String] = []
    for badge in item.badges {
        switch badge {
        case .isDefault: reasons.append("is the default \(noun)")
        case .pinned(let by): reasons.append("is pinned by \(by.joined(separator: ", "))")
        case .running: reasons.append("is running")
        case .openPR: reasons.append("has an open pull request")
        case .unpushed(let n): reasons.append("has \(n) unpushed commit\(n == 1 ? "" : "s")")
        default: continue
        }
    }
    guard !reasons.isEmpty else { return nil }
    return "\(item.title) \(reasons.sorted().joined(separator: " and "))."
}

/// Builds a plan from per-item steps, adding a warning for each in-use item.
func planEach(_ ids: [String], items: [Item], noun: String, _ steps: (Item) -> [Step]) -> Plan {
    var plan = Plan()
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for id in ids {
        guard let item = byID[id] else { continue }
        if let w = inUseWarning(item, noun: noun) { plan.warnings.append(w) }
        plan.steps += steps(item)
    }
    return plan
}

/// Sizes every item.
func measured(_ items: [Item]) async -> [Item] {
    var out: [Item] = []
    for var item in items {
        let m = await measure(item.paths)
        item.bytes = m.bytes
        item.sizeIsPartial = m.partial
        if m.partial && m.bytes == 0 { item.badges.insert(.locked) }
        out.append(item)
    }
    return out
}

/// Names of the visible folders inside `url`, sorted.
func subfolders(_ url: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    return names.filter { name in
        var isDir: ObjCBool = false
        return !name.hasPrefix(".") && FileManager.default.fileExists(atPath: url.appending(path: name).path, isDirectory: &isDir) && isDir.boolValue
    }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func firstLine(_ url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
}

/// The version a `.tool-versions` file in home selects for an asdf plugin.
func asdfGlobal(_ env: Environment, tool: String) -> String? {
    guard let text = try? String(contentsOf: env.path(".tool-versions"), encoding: .utf8) else { return nil }
    for line in text.split(whereSeparator: \.isNewline) {
        let words = line.split(separator: " ")
        if words.first.map(String.init) == tool, words.count > 1 { return String(words[1]) }
    }
    return nil
}

func pinBadge(_ pins: Pins, _ map: [String: [String]], installed: String) -> Badge? {
    let by = pins.pinners(of: map, installed: installed)
    return by.isEmpty ? nil : .pinned(by: by)
}
