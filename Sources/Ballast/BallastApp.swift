import BallastCore
import SwiftUI

@main
struct BallastApp: App {
    // Not @State: the Command Line Tools lack the SwiftUI macro plugin it needs on the macOS 27 SDK.
    private let model = AppModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { !model.prefs.quiet }, set: { model.prefs.quiet = !$0 })) {
            Popover(model: model)
        } label: {
            Image(systemName: model.lowSpace ? "scalemass.fill" : "scalemass")
        }
        .menuBarExtraStyle(.window)
        .commands {
            // The app menu shows while a window is open, which in quiet mode is the only way to Settings.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { Windows.shared.showSettings(AppModel.shared) }.keyboardShortcut(",")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening Ballast again from Finder or Spotlight shows its window, the way in while quiet mode hides the icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { Windows.shared.showMain(AppModel.shared) }
        return false
    }
}
