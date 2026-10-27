import BallastCore
import SwiftUI

@main
struct BallastApp: App {
    // Not @State: the Command Line Tools lack the SwiftUI macro plugin it needs on the macOS 27 SDK.
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            Popover(model: model)
        } label: {
            Image(systemName: model.lowSpace ? "scalemass.fill" : "scalemass")
        }
        .menuBarExtraStyle(.window)
    }
}
