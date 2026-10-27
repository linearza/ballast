import BallastCore
import Foundation

/// Settings kept in UserDefaults.
@MainActor @Observable final class Preferences {
    private let defaults = UserDefaults.standard

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

    init() {
        defaults.register(defaults: ["rescanHours": 24, "lowSpacePercent": 10])
        projectRoots = defaults.stringArray(forKey: "projectRoots") ?? []
        rescanHours = defaults.integer(forKey: "rescanHours")
        lowSpacePercent = defaults.integer(forKey: "lowSpacePercent")
        rootsConfirmed = defaults.bool(forKey: "rootsConfirmed")
    }

    var rootURLs: [URL] { projectRoots.map { URL(filePath: $0) } }
}
