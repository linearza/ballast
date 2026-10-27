import SwiftUI

@main
struct BallastApp: App {
    var body: some Scene {
        MenuBarExtra("Ballast", systemImage: "scalemass") {
            Text("Ballast").padding()
        }
        .menuBarExtraStyle(.window)
    }
}
