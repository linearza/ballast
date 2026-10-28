import AppKit

/// Whether this copy of an app is open. Matched by location, so a second Xcode isn't mistaken for the open one.
func isAppRunning(_ app: URL, running: [URL?] = NSWorkspace.shared.runningApplications.map(\.bundleURL)) -> Bool {
    let path = app.standardizedFileURL.path
    return running.contains { $0?.standardizedFileURL.path == path }
}

/// Whether any copy of an app is open.
func isAppRunning(bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}
