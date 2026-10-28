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
    /// Runs right before removal: a reason to skip each item that changed since the scan, by item id.
    func recheck(_ items: [Item], env: Environment, pins: Pins) async -> [String: Refusal]
}

extension Provider {
    public var needsUserStart: Bool { false }
    public func extraActions(_ items: [Item]) -> [ProviderAction] { [] }

    /// Scans once and compares every item against what it finds now.
    public func recheck(_ items: [Item], env: Environment, pins: Pins) async -> [String: Refusal] {
        let fresh = Dictionary(await scan(env, pins: pins).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var refusals: [String: Refusal] = [:]
        for item in items {
            guard let now = fresh[item.id] else {
                refusals[item.id] = Refusal(itemID: item.id, reason: "Already gone")
                continue
            }
            if now.inUse && !item.inUse {
                refusals[item.id] = Refusal(itemID: item.id, reason: newlyInUseReason(now.badges.subtracting(item.badges), noun: title))
            }
        }
        return refusals
    }
}

public enum Providers {
    public static let all: [any Provider] = [
        RubyProvider(), NodeProvider(), PythonProvider(), LanguagesProvider(), HomebrewProvider(), DockerProvider(), VirtualMachinesProvider(), XcodeProvider(), ProjectLeftoversProvider(), DatabasesProvider(), LoginItemsProvider(),
        PackageCachesProvider(), AppCachesProvider(), AIModelsProvider(), AppsProvider(), LargeFilesProvider(), OtherDevDataProvider(),
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
/// Real folders inside `url`, skipping hidden ones and symlinks (rvm's `default`, for one).
func subfolders(_ url: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    return names.filter { name in
        guard !name.hasPrefix("."),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.appending(path: name).path) else { return false }
        return attrs[.type] as? FileAttributeType == .typeDirectory
    }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

/// A server or VM started outside a service manager leaves a pid file in its folder,
/// like `postmaster.pid`, `<host>.pid` or Lima's `ha.pid`, whose first line is its pid.
func hasLivePidFile(_ dir: URL) -> Bool {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return files.filter { $0.hasSuffix(".pid") }.contains { file in
        guard let line = firstLine(dir.appending(path: file)), let pid = Int32(line.trimmingCharacters(in: .whitespaces)),
              pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
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

/// Where mise keeps a tool's versions, one folder each. Its alias links (`24`, `latest`) are skipped by `subfolders`.
func miseInstalls(_ env: Environment, tool: String) -> URL {
    env.path(".local/share/mise/installs/\(tool)")
}

/// The installed version mise's global config selects: an exact version, a prefix like `24`, or `latest`.
func miseGlobal(_ env: Environment, tools: [String], installed: [String]) -> String? {
    let config = (try? String(contentsOf: env.path(".config/mise/config.toml"), encoding: .utf8)).map(parseMiseTools) ?? [:]
    guard let wanted = tools.lazy.compactMap({ config[$0]?.first }).first ?? tools.lazy.compactMap({ asdfGlobal(env, tool: $0) }).first
    else { return nil }
    let newestFirst = installed.sorted { compareVersions($0, $1) == .orderedDescending }
    if ["latest", "lts"].contains(wanted) || wanted.hasPrefix("lts") { return newestFirst.first }
    return newestFirst.first { versionMatches(pin: wanted, installed: $0) }
}

func pinBadge(_ pins: Pins, _ map: [String: [String]], installed: String) -> Badge? {
    let by = pins.pinners(of: map, installed: installed)
    return by.isEmpty ? nil : .pinned(by: by)
}

/// Measures an item whose folders macOS protects. Only called when the user
/// asks, because reading them can bring up a permission prompt.
public func measureProtected(_ item: Item) async -> Item {
    var item = item
    let m = await measure(item.paths)
    item.bytes = m.bytes
    item.sizeIsPartial = m.partial
    if m.partial && m.bytes == 0 { item.badges.insert(.locked) } else { item.badges.remove(.locked) }
    return item
}

/// An item for folders Ballast doesn't read during scans: size unknown until measured.
func lockedItem(id: String, title: String, detail: String, paths: [URL], risk: Risk) -> Item {
    Item(id: id, title: title, detail: detail, paths: paths, bytes: 0, sizeIsPartial: true, risk: risk, badges: [.locked])
}
