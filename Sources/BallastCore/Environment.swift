import Foundation

/// Everything a provider reads from the outside world. Tests point it at a fixture tree.
public struct Environment: Sendable {
    public var home: URL
    public var brewPrefix: URL?
    public var applications: [URL]
    public var projectRoots: [URL]
    public var now: @Sendable () -> Date
    public var runner: any CommandRunner
    /// Moves a file to the Trash. Tests move it into a folder inside the fixture instead.
    public var trash: @Sendable (URL) throws -> Void
    /// `/` on a real Mac; the fixture in tests. Holds `usr/local/bin` and `Library`.
    public var systemRoot: URL

    public init(home: URL, brewPrefix: URL?, applications: [URL], projectRoots: [URL],
                now: @escaping @Sendable () -> Date = { Date() }, runner: any CommandRunner,
                trash: @escaping @Sendable (URL) throws -> Void, systemRoot: URL = URL(filePath: "/")) {
        self.home = home
        self.brewPrefix = brewPrefix
        self.applications = applications
        self.projectRoots = projectRoots
        self.now = now
        self.runner = runner
        self.trash = trash
        self.systemRoot = systemRoot
    }

    public func path(_ rel: String) -> URL { home.appending(path: rel) }
    public func system(_ rel: String) -> URL { systemRoot.appending(path: rel) }
}

extension Environment {
    /// The real Mac: your home folder, Homebrew wherever it's installed, the real Trash.
    public static func live(projectRoots: [URL]) -> Environment {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let brew = ["/opt/homebrew", "/usr/local"].map { URL(filePath: $0) }
            .first { fm.isExecutableFile(atPath: $0.appending(path: "bin/brew").path) }
        return Environment(
            home: home,
            brewPrefix: brew,
            applications: [URL(filePath: "/Applications"), home.appending(path: "Applications")],
            projectRoots: projectRoots,
            runner: ProcessRunner(),
            trash: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) })
    }
}
