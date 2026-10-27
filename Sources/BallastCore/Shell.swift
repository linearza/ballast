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

/// Quotes a string for zsh/sh. Plain words (letters, digits, `_ . / - + : @ %`) pass through.
public func shellQuote(_ s: String) -> String {
    let plain = !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_./-+:@%=".contains($0)) }
    if plain { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Runs real processes with the PATH a login shell would have, so tools from
/// Homebrew, rvm, nvm and friends are found the way they are in Terminal.
public struct ProcessRunner: CommandRunner {
    public init() {}

    static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Resolved once, on first use.
    static let loginPath: String = {
        let marker = "__BALLAST_PATH__"
        let r = execBlocking(URL(filePath: "/bin/zsh"), ["-lc", "printf '\(marker)%s' \"$PATH\""],
                             env: ProcessInfo.processInfo.environment, timeout: 10)
        guard r.ok, let range = r.stdout.range(of: marker) else { return withUserBin(fallbackPath) }
        let path = String(r.stdout[range.upperBound...])
        return withUserBin(path.isEmpty ? fallbackPath : path)
    }()

    /// mise's installer puts it in ~/.local/bin and adds that to .zshrc, which a login shell doesn't read.
    static func withUserBin(_ path: String) -> String {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path
        return path.split(separator: ":").contains(Substring(bin)) ? path : path + ":" + bin
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        return env
    }

    public func run(_ argv: [String], timeout: Duration) async -> CommandResult {
        guard let tool = argv.first else { return CommandResult(status: 127, stderr: "nothing to run") }
        let url: URL
        if tool.contains("/") {
            url = URL(filePath: tool)
        } else if let found = await which(tool) {
            url = found
        } else {
            return CommandResult(status: 127, stderr: "\(tool): not found")
        }
        let args = Array(argv.dropFirst())
        let env = Self.environment
        return await Task.detached { Self.execBlocking(url, args, env: env, timeout: timeout.seconds) }.value
    }

    public func shell(_ script: String, timeout: Duration) async -> CommandResult {
        let env = Self.environment
        return await Task.detached {
            Self.execBlocking(URL(filePath: "/bin/zsh"), ["-lc", script], env: env, timeout: timeout.seconds)
        }.value
    }

    public func which(_ tool: String) async -> URL? {
        for dir in Self.loginPath.split(separator: ":") {
            let candidate = URL(filePath: String(dir)).appending(path: tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Runs a process to completion on the calling thread. Output is collected
    /// as it arrives, so large output can't fill a pipe and stall the child.
    static func execBlocking(_ url: URL, _ args: [String], env: [String: String], timeout: Double) -> CommandResult {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Collector(), err = Collector()
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        out.attach(outPipe)
        err.attach(errPipe)

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do {
            try p.run()
        } catch {
            out.detach(outPipe)
            err.detach(errPipe)
            return CommandResult(status: 127, stderr: "\(url.lastPathComponent): \(error.localizedDescription)")
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // Give the readers a moment to drain; don't wait on grandchildren holding the pipe.
        out.waitForEOF(upTo: 1)
        err.waitForEOF(upTo: 1)
        out.detach(outPipe)
        err.detach(errPipe)

        if timedOut {
            let msg = "timed out after \(Int(timeout.rounded(.up))) s"
            return CommandResult(status: -1, stdout: out.string, stderr: err.string.isEmpty ? msg : err.string + "\n" + msg)
        }
        return CommandResult(status: p.terminationStatus, stdout: out.string, stderr: err.string)
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let eof = DispatchSemaphore(value: 0)

    func attach(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                eof.signal()
            } else {
                lock.withLock { data.append(chunk) }
            }
        }
    }

    func detach(_ pipe: Pipe) { pipe.fileHandleForReading.readabilityHandler = nil }
    func waitForEOF(upTo seconds: Double) { _ = eof.wait(timeout: .now() + seconds) }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
