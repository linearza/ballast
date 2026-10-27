import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { status == 0 }

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunner: Sendable {
    /// Runs a program directly, finding it on the login shell's PATH.
    func run(_ argv: [String], timeout: Duration) async -> CommandResult
    /// Runs a script with `/bin/zsh -lc`.
    func shell(_ script: String, timeout: Duration) async -> CommandResult
    func which(_ tool: String) async -> URL?
}

extension CommandRunner {
    public func run(_ argv: [String]) async -> CommandResult { await run(argv, timeout: .seconds(60)) }
    public func shell(_ script: String) async -> CommandResult { await shell(script, timeout: .seconds(60)) }
}
