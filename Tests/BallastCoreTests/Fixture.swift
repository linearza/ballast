import Foundation
@testable import BallastCore

/// A throwaway folder tree for one test. Removed when the fixture is released.
final class Fixture: @unchecked Sendable {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ballast-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Unreadable folders have to be made readable again before they can be removed.
        if let e = FileManager.default.enumerator(atPath: root.path) {
            while let rel = e.nextObject() as? String { chmod(root.appending(path: rel).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ rel: String) -> URL { root.appending(path: rel) }

    @discardableResult
    func file(_ rel: String, bytes: Int = 0, contents: String? = nil, modified: Date? = nil) -> URL {
        let u = url(rel)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = contents.map { Data($0.utf8) } ?? Data(repeating: 0x61, count: bytes)
        try! data.write(to: u)
        if let modified { try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path) }
        return u
    }

    @discardableResult
    func dir(_ rel: String) -> URL {
        let u = url(rel)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func link(_ rel: String, to dest: String) -> URL {
        let u = url(rel)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: u.path, withDestinationPath: dest.hasPrefix("/") ? dest : url(dest).path)
        return u
    }

    @discardableResult
    func hardlink(_ rel: String, to dest: String) -> URL {
        let u = url(rel)
        try! FileManager.default.linkItem(at: url(dest), to: u)
        return u
    }

    @discardableResult
    func unreadable(_ rel: String) -> URL {
        let u = dir(rel)
        file("\(rel)/inside.bin", bytes: 4096)
        chmod(u.path, 0)
        return u
    }
}

/// Answers commands from a table. Unknown commands fail with status 127.
/// Programs named in `passthrough` run for real (e.g. git against fixture repos).
final class FakeRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var responses: [String: CommandResult]
    var tools: Set<String>
    let passthrough: Set<String>

    init(_ responses: [String: CommandResult] = [:], tools: Set<String> = [], passthrough: Set<String> = []) {
        self.responses = responses
        self.tools = tools
        self.passthrough = passthrough
    }

    var calls: [String] { lock.withLock { _calls } }

    func run(_ argv: [String], timeout: Duration) async -> CommandResult {
        if let first = argv.first, passthrough.contains(first) {
            return await ProcessRunner().run(argv, timeout: timeout)
        }
        return answer(argv.joined(separator: " "))
    }

    func shell(_ script: String, timeout: Duration) async -> CommandResult { answer(script) }

    func which(_ tool: String) async -> URL? {
        if passthrough.contains(tool) { return await ProcessRunner().which(tool) }
        return tools.contains(tool) ? URL(filePath: "/usr/local/bin/\(tool)") : nil
    }

    private func answer(_ key: String) -> CommandResult {
        lock.withLock { _calls.append(key) }
        return responses[key] ?? CommandResult(status: 127, stderr: "not found")
    }

    static let ok = CommandResult(status: 0)
    static func out(_ s: String) -> CommandResult { CommandResult(status: 0, stdout: s) }
}

extension Fixture {
    /// An environment rooted at this fixture: home is the fixture, Homebrew lives in `opt/homebrew`.
    func env(runner: any CommandRunner = FakeRunner(), now: Date = Date(), roots: [String] = ["Projects"]) -> Environment {
        let trashDir = url(".Trash")
        let brew = url("opt/homebrew")
        return Environment(
            home: root,
            brewPrefix: FileManager.default.fileExists(atPath: brew.path) ? brew : nil,
            applications: [url("Applications")],
            projectRoots: roots.map { url($0) },
            now: { now },
            runner: runner,
            trash: { u in
                try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: u, to: trashDir.appending(path: "\(UUID().uuidString)-\(u.lastPathComponent)"))
            },
            systemRoot: root)
    }
}
