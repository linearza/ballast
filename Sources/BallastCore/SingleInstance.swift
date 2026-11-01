import Foundation

/// What a freshly opened Ballast does when other copies are already running.
public enum LaunchDecision: Equatable, Sendable {
    /// Nothing else is running, carry on.
    case proceed
    /// Hand over to the running copy and quit this one.
    case deferToRunning
    /// Every running copy is older: ask them to quit and take over.
    case replaceRunning
}

public enum SingleInstance {
    /// Numeric dotted version ("0.5.10" > "0.5.9"). Nil when empty or not just dot-separated numbers.
    public static func parse(_ version: String?) -> [Int]? {
        guard let version, !version.isEmpty else { return nil }
        var parts: [Int] = []
        for piece in version.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(piece), n >= 0 else { return nil }
            parts.append(n)
        }
        return parts
    }

    /// Compares two parsed versions, treating missing trailing parts as zero.
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Defer to any running copy that is the same, newer, or has a version we can't read.
    /// Take over only when we can read our own version and every other copy is strictly older.
    public static func decide(ours: String?, others: [String?]) -> LaunchDecision {
        if others.isEmpty { return .proceed }
        guard let mine = parse(ours) else { return .deferToRunning }
        for other in others {
            guard let theirs = parse(other), compare(theirs, mine) >= 0 else {
                if parse(other) == nil { return .deferToRunning }
                continue
            }
            return .deferToRunning
        }
        return .replaceRunning
    }
}
