import BallastCore
import SwiftUI

struct Popover: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            freeSpace
            if let summary = model.summary {
                Button { open(SafeView.id) } label: {
                    HStack {
                        Text("Safe to reclaim: \(formatBytes(model.safeToReclaim))").font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("See what's safe to remove")
                Divider()
                ForEach(summary.concerns.prefix(5), id: \.id) { c in
                    Button { open(c.id) } label: {
                        HStack {
                            Image(systemName: c.symbol).frame(width: 20)
                            Text(c.title)
                            Spacer()
                            Text(formatBytes(c.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(model.scanning ? "Scanning your disk…" : "No scan yet.").foregroundStyle(.secondary)
            }
            Divider()
            trash
            Divider()
            if let update = model.updates.available {
                Link("Ballast \(update.version) is out", destination: update.url).font(.callout)
            }
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    var freeSpace: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: 1 - model.freeFraction)
                .tint(model.freeFraction < 0.1 ? .red : model.freeFraction < 0.2 ? .orange : .accentColor)
            HStack {
                Text("\(formatBytes(model.free)) free of \(formatBytes(model.total))")
                    .font(.callout).monospacedDigit()
                Spacer()
                // Here rather than in the footer, which has no room for it next to the buttons.
                if model.scanning {
                    Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                } else if let at = model.summary?.scannedAt {
                    Text("Scanned \(relativeScanTime(at, now: Date()))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var trash: some View {
        HStack {
            Image(systemName: "trash").frame(width: 20)
            Text("Trash")
            Spacer()
            if let bytes = model.trashBytes {
                Text(formatBytes(bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Empty") { Task { await model.emptyTrash() } }
                .disabled(model.trashBytes == 0)
        }
    }

    var footer: some View {
        HStack {
            if model.scanning { ProgressView().controlSize(.small) }
            Spacer()
            Button("Scan now") { Task { await model.scanNow() } }.disabled(model.scanning)
            Button("Open Ballast") { open(nil) }
            Menu {
                Button("Settings…") { Windows.shared.showSettings(model) }
                Button("Go Quiet…") { goQuiet(model) }
                Divider()
                Button("Quit Ballast") { NSApp.terminate(nil) }
            } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }

    func open(_ concern: String?) {
        if let concern { model.selection = concern }
        Windows.shared.showMain(model)
    }
}
