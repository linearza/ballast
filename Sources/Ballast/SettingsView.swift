import AppKit
import BallastCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    /// Re-read after toggling, since SMAppService has no change notification.
    let login = LoginItem()

    var prefs: Preferences { model.prefs }

    var body: some View {
        Form {
            SwiftUI.Section("Project folders") {
                RootsEditor(roots: Binding(get: { prefs.projectRoots }, set: { prefs.projectRoots = $0 }))
                Text("Used to see which versions your projects pin and to find project leftovers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Scanning") {
                Picker("Rescan in the background", selection: Binding(get: { prefs.rescanHours }, set: {
                    prefs.rescanHours = $0
                    model.startSchedule()
                })) {
                    Text("Off").tag(0)
                    Text("Every 6 hours").tag(6)
                    Text("Every 24 hours").tag(24)
                }
                Stepper("Warn when free space is below \(prefs.lowSpacePercent)%",
                        value: Binding(get: { prefs.lowSpacePercent }, set: { prefs.lowSpacePercent = $0 }), in: 1...50)
                Stepper("node_modules idle after \(prefs.idleDays) days",
                        value: Binding(get: { prefs.idleDays }, set: { prefs.idleDays = $0 }), in: 7...365, step: 7)
            }
            SwiftUI.Section("General") {
                Toggle("Open Ballast at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if let note = login.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                if let update = model.updates.available {
                    Link("Ballast \(update.version) is out", destination: update.url)
                } else {
                    Text("Ballast \(model.updates.current)").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { login.refresh() }
    }
}

@MainActor @Observable final class LoginItem {
    var status = SMAppService.mainApp.status
    var error: String?

    var enabled: Bool { status == .enabled }

    var note: String? {
        if Screenshots.directory != nil { return nil }
        if let error { return error }
        switch status {
        case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items."
        case .notFound: return "macOS can't find Ballast as a login item. Move it to Applications and try again."
        default: return nil
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

/// A list of folders with Add folder… and remove.
struct RootsEditor: View {
    let roots: Binding<[String]>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(roots.wrappedValue, id: \.self) { path in
                HStack {
                    Image(systemName: "folder")
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    Spacer()
                    Button { roots.wrappedValue.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add folder…") {
                if let url = chooseFolder(), !roots.wrappedValue.contains(url.path) { roots.wrappedValue.append(url.path) }
            }
        }
    }
}

@MainActor func chooseFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    return panel.runModal() == .OK ? panel.url : nil
}

/// "Where are your projects?": detected folders, pre-ticked.
struct FirstRunSheet: View {
    let model: AppModel
    let choice = RootChoice()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where are your projects?").font(.title3.bold())
            Text("Ballast looks in these folders to see which language versions your projects use, so it never suggests removing one they need, and to find leftovers like old node_modules.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(choice.found, id: \.self) { path in
                Toggle(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), isOn: Binding(
                    get: { choice.ticked.contains(path) },
                    set: { on in if on { choice.ticked.insert(path) } else { choice.ticked.remove(path) } }))
            }
            if choice.found.isEmpty {
                Text("No project folders found. Add one, or continue without.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Add folder…") {
                    if let url = chooseFolder(), !choice.found.contains(url.path) {
                        choice.found.append(url.path)
                        choice.ticked.insert(url.path)
                    }
                }
                Spacer()
                Button("Continue") {
                    Task { await model.confirmRoots(choice.found.filter { choice.ticked.contains($0) }) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

@MainActor @Observable final class RootChoice {
    var found: [String]
    var ticked: Set<String>

    init() {
        let paths = detectProjectRoots(home: FileManager.default.homeDirectoryForCurrentUser).map(\.path)
        found = paths
        ticked = Set(paths)
    }
}
