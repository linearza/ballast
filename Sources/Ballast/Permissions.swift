import AppKit
import SwiftUI

struct PermissionProblemInfo: Identifiable {
    let id = UUID()
    var path: URL?
    /// Measuring a protected folder worked before, so macOS dropped the grant (usually after a rebuild).
    var forgot: Bool
}

struct PermissionsSheet: View {
    let info: PermissionProblemInfo
    let close: () -> Void

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(info.forgot ? "macOS forgot Ballast's access after the rebuild" : "Ballast needs Full Disk Access for this")
                .font(.title3.bold())
            Text("macOS protects this folder. To measure or remove it, allow Ballast in System Settings → Privacy & Security → Full Disk Access.")
            if let path = info.path {
                Text(path.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("After an update, macOS may forget this. Turn Ballast off and on again in the list.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now", action: close).keyboardShortcut(.cancelAction)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(Self.settingsURL)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
