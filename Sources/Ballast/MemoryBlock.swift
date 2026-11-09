import AppKit
import BallastCore
import SwiftUI

/// The top of the menu while memory is strained: how full it is, then the groups holding most of it, each with a Close.
struct MemoryBlock: View {
    let model: AppModel
    private let closer = MemoryCloser.shared

    var body: some View {
        let memory = model.memory
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "memorychip.fill").foregroundStyle(Theme.danger).frame(width: 20)
                Text(memory.usedPercent.map { "Memory \($0)% used" } ?? "Memory is under strain").font(.headline)
            }
            if memory.swapUsed > 1 << 30 {
                Text("\(formatBytes(memory.swapUsed)) swapped out to disk").font(.caption).foregroundStyle(Theme.muted).padding(.leading, 28)
            }
            if memory.culprits.isEmpty {
                Text("Nothing Ballast can measure stands out. It can't see inside macOS's or other users' processes.")
                    .font(.caption).foregroundStyle(Theme.muted).padding(.leading, 28)
            } else {
                ForEach(memory.culprits, id: \.group.id) { c in row(c) }
            }
        }
    }

    private func row(_ c: Culprit) -> some View {
        let option = closeOption(for: c.group, myUID: getuid(), myPID: ProcessInfo.processInfo.processIdentifier)
        let name = culpritName(c)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(culpritDetails(c)).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                switch option {
                case .notOffered:
                    EmptyView()
                default:
                    Button("Close") { Task { await closer.close(c.group, option: option, memory: model.memory) } }
                        .buttonStyle(DangerButtonStyle(outline: true))
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("Close \(name)")
                        .disabled(closer.closing.contains(c.group.id))
                }
            }
            if case .notOffered(let reason) = option {
                Text(reason).font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(.leading, 28)
    }
}

/// Asks, then closes, one group at a time. Never closes anything without a confirmation, and never retries.
@MainActor @Observable final class MemoryCloser {
    static let shared = MemoryCloser()
    private(set) var closing: Set<String> = []
    @ObservationIgnored private let control = LiveProcessControl()

    func close(_ group: MemoryGroup, option: CloseOption, memory: MemoryMonitor) async {
        guard !closing.contains(group.id) else { return }
        closing.insert(group.id)
        defer { closing.remove(group.id) }
        switch option {
        case .notOffered:
            return
        case .app(let bundlePath, let skipped):
            await closeApp(group, bundlePath: bundlePath, skipped: skipped)
        case .processes(let samples, let skipped):
            await closeProcesses(group, samples: samples, skipped: skipped)
        }
        await memory.refreshForMenu()
    }

    // MARK: Apps

    private func closeApp(_ group: MemoryGroup, bundlePath: String, skipped: Int) async {
        guard confirm(group, skipped: skipped) else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == bundlePath }
        guard !apps.isEmpty else {
            say("Couldn't find \(group.name)", "Ballast couldn't find \(group.name) running as an app, so it closed nothing.")
            return
        }
        for app in apps { app.terminate() }
        await wait(seconds: 5) { apps.allSatisfy(\.isTerminated) }
        var left = apps.filter { !$0.isTerminated }
        if !left.isEmpty {
            let force = ask("\(group.name) is still running",
                            "It hasn't closed after 5 seconds. Force Quit ends it immediately, and anything unsaved in it is lost.",
                            go: "Force Quit")
            if force {
                for app in left { app.forceTerminate() }
                await wait(seconds: 2) { left.allSatisfy(\.isTerminated) }
                left = left.filter { !$0.isTerminated }
            }
        }
        if !left.isEmpty { say("\(group.name) is still running", "It didn't close. You can quit it yourself from the Dock.") }
    }

    // MARK: Plain processes

    private func closeProcesses(_ group: MemoryGroup, samples: [ProcessSample], skipped: Int) async {
        guard confirm(group, skipped: skipped, listing: samples) else { return }
        let control = control
        var refused = signalAll(samples, signal: SIGTERM, control: control).refused
        await sleep(seconds: 3)
        var left = survivors(samples, control: control)
        if !left.isEmpty {
            let force = ask("\(left.count) \(left.count == 1 ? "process is" : "processes are") still running",
                            "They haven't stopped after 3 seconds. Force Stop ends them immediately, and anything unsaved in them is lost.",
                            go: "Force Stop")
            if force {
                refused += signalAll(left, signal: SIGKILL, control: control).refused
                await sleep(seconds: 1)
                left = survivors(left, control: control)
            }
        }
        var lines: [String] = []
        if !left.isEmpty { lines.append("\(left.count) \(left.count == 1 ? "is" : "are") still running.") }
        let gone = Set(refused).subtracting(left.map(\.pid))
        if !gone.isEmpty { lines.append("\(gone.count) already gone or changed, so Ballast left \(gone.count == 1 ? "it" : "them") alone.") }
        if !lines.isEmpty { say("Not everything closed", lines.joined(separator: " ")) }
    }

    // MARK: Waiting

    private func sleep(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func wait(seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { await sleep(seconds: 0.25) }
    }

    // MARK: Alerts

    /// Cancel is the default button, as in emptyTrash(): closing takes a deliberate click.
    private func ask(_ title: String, _ text: String, go: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let action = alert.addButton(withTitle: go)
        let cancel = alert.addButton(withTitle: "Cancel")
        action.hasDestructiveAction = true
        action.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func say(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private func confirm(_ group: MemoryGroup, skipped: Int, listing: [ProcessSample]? = nil) -> Bool {
        let shown = (listing ?? group.processes).sorted { $0.footprint > $1.footprint }
        let home = NSHomeDirectory()
        var lines = shown.prefix(10).map { p in
            var line = "\(processLabel(p)) (\(p.pid)) · \(formatBytes(p.footprint))"
            if let cwd = p.cwd, !cwd.isEmpty { line += " · \(abbreviatingHome(cwd, home: home))" }
            return line
        }
        if shown.count > 10 { lines.append("and \(shown.count - 10) more") }
        var text = lines.joined(separator: "\n") + "\n\nAnything you haven't saved in \(group.name) will be lost."
        if skipped > 0 {
            text += "\n\(skipped) other \(skipped == 1 ? "process" : "processes") in this group won't be touched, because Ballast can't safely close \(skipped == 1 ? "it" : "them")."
        }
        return ask("Close \(group.name)?", text, go: "Close")
    }
}
