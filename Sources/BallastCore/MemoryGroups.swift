import Foundation

/// One running process, as read at a moment in time.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var startSeconds: UInt64
    public var uid: UInt32
    public var path: String?
    public var args: [String]
    public var cwd: String?
    public var footprint: Int64

    public init(pid: Int32, startSeconds: UInt64, uid: UInt32, path: String?, args: [String], cwd: String?, footprint: Int64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.uid = uid
        self.path = path
        self.args = args
        self.cwd = cwd
        self.footprint = footprint
    }
}

/// Processes that belong together, shown under one name.
public struct MemoryGroup: Equatable, Sendable {
    public var id: String
    public var name: String
    public var processes: [ProcessSample]
    public var bytes: Int64

    public init(id: String, name: String, processes: [ProcessSample], bytes: Int64) {
        self.id = id
        self.name = name
        self.processes = processes
        self.bytes = bytes
    }
}

public struct SystemMemory: Equatable, Sendable {
    public var physical: Int64
    public var used: Int64
    public var swapUsed: Int64

    public init(physical: Int64, used: Int64, swapUsed: Int64) {
        self.physical = physical
        self.used = used
        self.swapUsed = swapUsed
    }

    /// Memory used as a whole percent of physical, or nil when physical memory is unknown.
    public var usedPercent: Int? {
        guard physical > 0 else { return nil }
        let pct = (Double(used) / Double(physical) * 100).rounded()
        return Int(min(100, max(0, pct)))
    }
}

let runtimeNames: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby"]

private func lastComponent(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
}

/// The last `node_modules/<tool>/` in any argument that isn't pnpm's `.pnpm` store folder.
private func toolName(in args: [String]) -> String? {
    var found: String?
    for arg in args {
        let parts = arg.split(separator: "/", omittingEmptySubsequences: true)
        for (i, part) in parts.enumerated() where part == "node_modules" && i + 1 < parts.count {
            let next = String(parts[i + 1])
            if next == ".pnpm" { continue }
            if next.hasPrefix("@"), i + 2 < parts.count {
                found = "\(next)/\(parts[i + 2])"
            } else {
                found = next
            }
        }
    }
    return found
}

private func identity(of p: ProcessSample) -> (id: String, name: String) {
    guard let path = p.path else { return ("unknown", "Unknown process") }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    // Helpers live inside the app that launched them, so the outermost .app wins.
    if let idx = components.firstIndex(where: { $0.hasSuffix(".app") }) {
        let app = String(components[idx])
        let prefix = "/" + components[...idx].joined(separator: "/")
        return ("app:\(prefix)", String(app.dropLast(4)))
    }
    let exe = lastComponent(path)
    if runtimeNames.contains(exe) {
        if let tool = toolName(in: p.args) { return ("tool:\(tool)", tool) }
        if let cwd = p.cwd, !cwd.isEmpty, cwd != "/" {
            return ("runtime:\(exe):\(cwd)", "\(exe) · \(lastComponent(cwd))")
        }
        return ("runtime:\(exe)", exe)
    }
    return ("exe:\(path)", exe)
}

/// Collapses processes into the things a person recognises: apps, dev tools, plain executables.
/// Largest group first.
public func groupProcesses(_ samples: [ProcessSample]) -> [MemoryGroup] {
    var order: [String] = []
    var groups: [String: MemoryGroup] = [:]
    for s in samples {
        let (id, name) = identity(of: s)
        if groups[id] == nil {
            order.append(id)
            groups[id] = MemoryGroup(id: id, name: name, processes: [], bytes: 0)
        }
        groups[id]?.processes.append(s)
        groups[id]?.bytes += s.footprint
    }
    return order.compactMap { groups[$0] }.sorted { $0.bytes > $1.bytes }
}
