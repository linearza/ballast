import Darwin
import Foundation

public enum CloseOption: Equatable, Sendable {
    case app(bundlePath: String, skipped: Int)
    case processes([ProcessSample], skipped: Int)
    case notOffered(String)
}

private let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/bin/", "/usr/bin/", "/Library/Apple/"]

private let macOSReason = "That's part of macOS, so Ballast won't close it."
private let otherUserReason = "That belongs to another user, so Ballast won't close it."
private let unidentifiedReason = "Ballast can't tell what that is, so it won't close it."

private func isSystemPath(_ path: String) -> Bool {
    systemPrefixes.contains { path.hasPrefix($0) }
}

/// What may be offered for closing. Only this user's own, non-system processes, and never Ballast.
public func closeOption(for group: MemoryGroup, myUID: UInt32, myPID: Int32) -> CloseOption {
    if group.processes.contains(where: { $0.pid == myPID }) {
        return .notOffered("That's Ballast itself.")
    }
    let mine = group.processes.filter { $0.uid == myUID }
    let notMine = group.processes.count - mine.count

    if group.id.hasPrefix("app:") {
        let bundle = String(group.id.dropFirst(4))
        if isSystemPath(bundle) { return .notOffered(macOSReason) }
        if mine.isEmpty { return .notOffered(otherUserReason) }
        return .app(bundlePath: bundle, skipped: notMine)
    }

    let closable = mine.filter { p in
        guard let path = p.path else { return false }
        return !isSystemPath(path)
    }
    if closable.isEmpty {
        if group.processes.contains(where: { $0.path.map(isSystemPath) ?? false }) { return .notOffered(macOSReason) }
        if mine.count < group.processes.count { return .notOffered(otherUserReason) }
        return .notOffered(unidentifiedReason)
    }
    return .processes(closable, skipped: group.processes.count - closable.count)
}

public protocol ProcessControl: Sendable {
    func identity(pid: Int32) -> (startSeconds: UInt64, path: String?)?
    func signal(pid: Int32, _ sig: Int32) -> Bool
}

public struct LiveProcessControl: ProcessControl {
    public init() {}

    public func identity(pid: Int32) -> (startSeconds: UInt64, path: String?)? {
        guard let s = LiveMemoryReader.sample(pid: pid) else { return nil }
        return (s.startSeconds, s.path)
    }

    public func signal(pid: Int32, _ sig: Int32) -> Bool {
        kill(pid, sig) == 0
    }
}

public struct CloseOutcome: Equatable, Sendable {
    public var signalled: [Int32]
    public var refused: [Int32]

    public init(signalled: [Int32], refused: [Int32]) {
        self.signalled = signalled
        self.refused = refused
    }
}

private func stillSame(_ s: ProcessSample, _ control: any ProcessControl) -> Bool {
    guard let now = control.identity(pid: s.pid), let path = now.path, let was = s.path else { return false }
    return now.startSeconds == s.startSeconds && path == was
}

/// Signals each process only if it is still the very process that was sampled.
/// Never signals pid <= 1: `kill` with 0 or a negative pid targets a whole process group.
public func signalAll(_ samples: [ProcessSample], signal sig: Int32, control: any ProcessControl) -> CloseOutcome {
    var outcome = CloseOutcome(signalled: [], refused: [])
    for s in samples {
        if s.pid > 1, stillSame(s, control), control.signal(pid: s.pid, sig) {
            outcome.signalled.append(s.pid)
        } else {
            outcome.refused.append(s.pid)
        }
    }
    return outcome
}

/// The sampled processes that are still the same running process.
public func survivors(_ samples: [ProcessSample], control: any ProcessControl) -> [ProcessSample] {
    samples.filter { $0.pid > 1 && stillSame($0, control) }
}
