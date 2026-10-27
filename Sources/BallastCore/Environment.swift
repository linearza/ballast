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

    public init(home: URL, brewPrefix: URL?, applications: [URL], projectRoots: [URL],
                now: @escaping @Sendable () -> Date = { Date() }, runner: any CommandRunner,
                trash: @escaping @Sendable (URL) throws -> Void) {
        self.home = home
        self.brewPrefix = brewPrefix
        self.applications = applications
        self.projectRoots = projectRoots
        self.now = now
        self.runner = runner
        self.trash = trash
    }

    public func path(_ rel: String) -> URL { home.appending(path: rel) }
}
