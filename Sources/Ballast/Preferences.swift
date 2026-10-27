import BallastCore
import Foundation

/// Settings kept in UserDefaults.
@MainActor @Observable final class Preferences {
    private let defaults: UserDefaults

    /// Project roots as paths. Empty until the first run detects and confirms them.
    var projectRoots: [String] {
        didSet { defaults.set(projectRoots, forKey: "projectRoots") }
    }
    /// 0 = off, 6 or 24.
    var rescanHours: Int {
        didSet { defaults.set(rescanHours, forKey: "rescanHours") }
    }
    /// Notify when free space drops below this percentage.
    var lowSpacePercent: Int {
        didSet { defaults.set(lowSpacePercent, forKey: "lowSpacePercent") }
    }
    var rootsConfirmed: Bool {
        didSet { defaults.set(rootsConfirmed, forKey: "rootsConfirmed") }
    }
    /// Days without activity before a project's node_modules counts as safe to remove.
    var idleDays: Int {
        didSet { defaults.set(idleDays, forKey: "idleDays") }
    }
    /// Set once measuring a protected folder worked, so a later failure means macOS forgot the grant.
    var hadFullDiskAccess: Bool {
        didSet { defaults.set(hadFullDiskAccess, forKey: "hadFullDiskAccess") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["rescanHours": 24, "lowSpacePercent": 10, "idleDays": 60])
        projectRoots = defaults.stringArray(forKey: "projectRoots") ?? []
        rescanHours = defaults.integer(forKey: "rescanHours")
        lowSpacePercent = defaults.integer(forKey: "lowSpacePercent")
        rootsConfirmed = defaults.bool(forKey: "rootsConfirmed")
        hadFullDiskAccess = defaults.bool(forKey: "hadFullDiskAccess")
        idleDays = defaults.integer(forKey: "idleDays")
    }

    var rootURLs: [URL] { projectRoots.map { URL(filePath: $0) } }
}
