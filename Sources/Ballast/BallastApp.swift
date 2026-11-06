import BallastCore
import SwiftUI

/// Entry point. `BALLAST_SELFUPDATE_TEST=<bundle>` runs the installer against that bundle and exits, with no app and no window.
@main
enum Launcher {
    static func main() {
        if let target = SelfUpdateTestHook.target {
            Task.detached { exit(await SelfUpdateTestHook.run(target)) }
            dispatchMain()
        }
        BallastApp.main()
    }
}

struct BallastApp: App {
    // Not @State: the Command Line Tools lack the SwiftUI macro plugin it needs on the macOS 27 SDK.
    private let model = AppModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { !model.prefs.quiet }, set: { model.prefs.quiet = !$0 })) {
            Popover(model: model)
        } label: {
            let symbol = menuBarSymbol(memoryRed: model.memory.isRed, lowSpace: model.lowSpace)
            if model.memory.isRed, let percent = model.memory.usedPercent {
                // One Text with an inline image: MenuBarExtra labels keep a single image or text run, so an HStack/Label can drop one.
                Text("\(Image(systemName: symbol)) \(percent)%")
            } else {
                Image(systemName: symbol)
            }
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
    private static let showName = Notification.Name("za.co.linear.ballast.show")
    private static let quitName = Notification.Name("za.co.linear.ballast.quit")

    /// One Ballast at a time: runs before the menu bar item or any scan, so a second copy never flashes an icon.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let center = DistributedNotificationCenter.default()
        if Screenshots.directory != nil { return }  // screenshot mode may run beside the real app
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "za.co.linear.ballast")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        let ours = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        switch SingleInstance.decide(ours: ours, others: others.map(Self.version)) {
        case .proceed: break
        case .deferToRunning: Self.handOff(to: others, center)
        case .replaceRunning:
            center.postNotificationName(Self.quitName, object: nil, userInfo: nil, deliverImmediately: true)
            // Copies that don't know the notification get a plain quit request after a moment.
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            for app in others where !app.isTerminated { app.terminate() }
            // Wait for them to go, but not forever. One that is mid-clean ignores the request.
            let deadline = Date().addingTimeInterval(5)
            while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if others.contains(where: { !$0.isTerminated }) { Self.handOff(to: others, center) }
        }
        center.addObserver(forName: Self.showName, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Windows.shared.showMain(AppModel.shared) }
        }
        center.addObserver(forName: Self.quitName, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                NSApp.terminate(nil)  // applicationShouldTerminate refuses mid-clean
            }
        }
    }

    /// A copy that is mid-clean ignores every request to quit, so a newer copy defers to it instead.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.run?.phase == .running ? .terminateCancel : .terminateNow }
    }

    /// The other copy's version, read from its own Info.plist.
    private static func version(of app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Asks the running copy to open its window, then leaves without ever showing an icon.
    private static func handOff(to others: [NSRunningApplication], _ center: DistributedNotificationCenter) -> Never {
        center.postNotificationName(showName, object: nil, userInfo: nil, deliverImmediately: true)
        others.first?.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))  // let the notification out
        exit(0)
    }

    /// Opening Ballast again from Finder or Spotlight shows its window, the way in while quiet mode hides the icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { Windows.shared.showMain(AppModel.shared) }
        return false
    }
}
