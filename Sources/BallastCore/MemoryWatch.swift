import Foundation

// Thresholds. Percentages are of physical memory.
private let redShareOfPhysical = 50          // top group at or above this goes red
private let clearShareOfPhysical = 40        // top group must fall below this to clear
private let jumpShareOfPhysical = 25         // used rising by this much...
private let jumpWindowSeconds: TimeInterval = 120  // ...within this many seconds is a jump
private let minimumRedSeconds: TimeInterval = 60   // stays red at least this long
private let minimumTotalsSpacing: TimeInterval = 20  // extra readings closer than this aren't stored
private let totalsWindowSize = 5             // readings of "used" kept, nothing more
private let breakdownUsedPercent = 50        // below this (and calm) no breakdown is needed
private let culpritSharePercent = 15         // a group needs this share to be named
private let culpritLimit = 3
private let growthMinimumBytes: Int64 = 1 << 30

public enum MemoryPressure: Sendable { case normal, warning, critical }

/// Decides whether the menu bar icon should be red. Holds at most five recent totals, in memory only.
public struct MemoryWatch: Sendable {
    private struct Total: Sendable { var used: Int64; var at: Date }

    public private(set) var isRed: Bool = false
    private var redSince: Date?
    private var totals: [Total] = []

    public init() {}

    var storedTotalsCount: Int { totals.count }

    private func hasJump(system: SystemMemory, now: Date) -> Bool {
        guard system.physical > 0 else { return false }
        let needed = system.physical * Int64(jumpShareOfPhysical)
        return totals.contains { t in
            let age = now.timeIntervalSince(t.at)
            return age >= 0 && age <= jumpWindowSeconds && (system.used - t.used) * 100 >= needed
        }
    }

    /// False only when memory is calm enough that no single app can be the problem.
    public func needsBreakdown(system: SystemMemory, pressure: MemoryPressure, now: Date) -> Bool {
        guard system.physical > 0 else { return false }
        if isRed || pressure != .normal { return true }
        if system.used * 100 >= system.physical * Int64(breakdownUsedPercent) { return true }
        return hasJump(system: system, now: now)
    }

    /// `topGroupBytes` is nil when no breakdown was taken: that counts as no known hog.
    public mutating func update(system: SystemMemory, pressure: MemoryPressure, topGroupBytes: Int64?, now: Date) {
        defer {
            if let newest = totals.last, now >= newest.at, now.timeIntervalSince(newest.at) < minimumTotalsSpacing {
                // Too soon after the last stored reading; keep the older ones the jump rule needs.
            } else {
                totals.append(Total(used: system.used, at: now))
            }
            if totals.count > totalsWindowSize { totals.removeFirst(totals.count - totalsWindowSize) }
        }
        guard system.physical > 0 else {
            isRed = false
            redSince = nil
            return
        }
        if let since = redSince, now < since { redSince = now }
        let top = (topGroupBytes ?? 0) * 100
        let jump = hasJump(system: system, now: now)
        let triggered = pressure != .normal || top >= system.physical * Int64(redShareOfPhysical) || jump
        if triggered {
            if !isRed { redSince = now }
            isRed = true
            return
        }
        guard isRed else { return }
        let calm = top < system.physical * Int64(clearShareOfPhysical)
        let longEnough = redSince.map { now.timeIntervalSince($0) >= minimumRedSeconds } ?? true
        if calm && longEnough {
            isRed = false
            redSince = nil
        }
    }
}

/// An earlier size of a group, kept to say how much it has grown.
public struct GroupReading: Equatable, Sendable {
    public var bytes: Int64
    public var at: Date

    public init(bytes: Int64, at: Date) {
        self.bytes = bytes
        self.at = at
    }
}

public struct Culprit: Equatable, Sendable {
    public var group: MemoryGroup
    /// Whole percent of physical memory.
    public var share: Int
    public var growth: Int64?
    public var growthSeconds: Int?

    public init(group: MemoryGroup, share: Int, growth: Int64?, growthSeconds: Int?) {
        self.group = group
        self.share = share
        self.growth = growth
        self.growthSeconds = growthSeconds
    }
}

/// Up to three groups holding at least 15% of physical memory, largest first.
/// Growth is only given when an earlier reading exists and the group grew by at least 1 GB.
public func culprits(_ groups: [MemoryGroup], physical: Int64, previous: [String: GroupReading], now: Date) -> [Culprit] {
    guard physical > 0 else { return [] }
    return groups
        .sorted { $0.bytes > $1.bytes }
        .filter { $0.bytes * 100 >= physical * Int64(culpritSharePercent) }
        .prefix(culpritLimit)
        .map { g in
            let share = Int(min(100, max(0, (Double(g.bytes) / Double(physical) * 100).rounded())))
            var growth: Int64?
            var seconds: Int?
            if let earlier = previous[g.id], g.bytes - earlier.bytes >= growthMinimumBytes {
                growth = g.bytes - earlier.bytes
                seconds = max(0, Int(now.timeIntervalSince(earlier.at)))
            }
            return Culprit(group: g, share: share, growth: growth, growthSeconds: seconds)
        }
}

/// The menu bar symbol: memory strain first, then low disk space, then the calm one.
public func menuBarSymbol(memoryRed: Bool, lowSpace: Bool) -> String {
    if memoryRed { return "memorychip.fill" }
    return lowSpace ? "scalemass.fill" : "scalemass"
}

private func growthDuration(_ seconds: Int) -> String {
    if seconds < 120 { return "\(seconds) s" }
    if seconds < 3600 * 2 { return "\(seconds / 60) min" }
    return "\(seconds / 3600) hr"
}

/// One row of text for a culprit: name, process count (groups only), size, share, and growth when measured.
public func culpritLine(_ c: Culprit) -> String {
    var parts = [c.group.name]
    if c.group.processes.count > 1 { parts.append("\(c.group.processes.count) processes") }
    parts.append(formatBytes(c.group.bytes))
    parts.append("\(c.share)% of memory")
    var line = parts.joined(separator: " · ")
    if let growth = c.growth, let seconds = c.growthSeconds {
        line += " · up \(formatBytes(growth)) in \(growthDuration(seconds))"
    }
    return line
}
