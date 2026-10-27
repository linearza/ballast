import AppKit
import SwiftUI

/// Opens Ballast's windows with AppKit. SwiftUI's openWindow/openSettings need
/// @Environment, which the Command Line Tools can't expand on the macOS 27 SDK.
@MainActor final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    private var main: NSWindow?
    private var settings: NSWindow?

    func showMain(_ model: AppModel) {
        if main == nil {
            main = window("Ballast", size: NSSize(width: 900, height: 600), resizable: true,
                          content: MainWindowRoot(model: model))
            main?.setFrameAutosaveName("BallastMain")
        }
        bringForward(main)
    }

    func showSettings(_ model: AppModel) {
        if settings == nil {
            settings = window("Ballast Settings", size: NSSize(width: 520, height: 440), resizable: false,
                              content: SettingsView(model: model))
        }
        bringForward(settings)
    }

    private func window(_ title: String, size: NSSize, resizable: Bool, content: some View) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: content)
        w.setContentSize(size)
        w.center()
        w.delegate = self
        return w
    }

    /// Ballast lives in the menu bar, but shows in the Dock and app switcher while one of its windows is open.
    private func bringForward(_ w: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === main {
            main = nil
            AppModel.shared.releaseItems()
        }
        if w === settings { settings = nil }
        if main == nil && settings == nil { NSApp.setActivationPolicy(.accessory) }
    }
}
