import AppKit
import BallastCore
import SwiftUI

/// A MenuBarExtra window keeps the tallest height it has been, so when a block goes away the panel hangs
/// below the menu bar with a transparent gap above it. This keeps the window as tall as the content, top edge fixed.
/// Put it in the popover's `.background`; it measures the content itself.
struct PopoverFit: View {
    var body: some View {
        // No @State (the Command Line Tools lack its macro plugin): the measured height goes straight to the window.
        GeometryReader { geo in
            Anchor(height: geo.size.height)
        }
    }

    private struct Anchor: NSViewRepresentable {
        let height: CGFloat

        func makeNSView(context: Context) -> NSView { NSView() }

        func updateNSView(_ view: NSView, context: Context) {
            guard Screenshots.directory == nil else { return }  // offscreen renders have no menu bar to hang from
            let height = height
            // The window isn't attached on first appear, and resizing mid-update can re-enter layout.
            DispatchQueue.main.async { [weak view] in
                guard let window = view?.window, window is NSPanel else { return }  // the popover's window, never the main one
                let target = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 1, height: height)).height
                guard let frame = topAnchoredFrame(window.frame, contentHeight: target) else { return }
                window.setFrame(frame, display: true)
            }
        }
    }
}
