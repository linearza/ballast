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
            if let phone = model.iphone, let block = iphoneBlock(phone) {
                Divider()
                block
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

    /// A connected iPhone as a name, a thin storage bar and one line on what fills it. Nil when there is nothing to show.
    func iphoneBlock(_ phone: IPhoneSnapshot) -> AnyView? {
        let help = "See what's using \(phone.name)'s storage"
        switch phone.state {
        case .locked:
            return AnyView(Button { open(IPhoneDetail.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "iphone").frame(width: 20)
                        Text(phone.name)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    Text("Unlock it and tap Trust").font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help))
        default:
            guard let storage = phone.storage else { return nil }
            return AnyView(Button { open(IPhoneDetail.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "iphone").frame(width: 20)
                        Text(phone.name).lineLimit(1)
                        Spacer()
                        Text("\(formatBytes(storage.free)) free").monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    StorageBar(storage: storage, height: 6).padding(.leading, 28)
                    iphoneCaption(storage, videos: phone.media.videoBytes).padding(.leading, 28)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help))
        }
    }

    /// One line, longest first; the first version that fits whole is shown, so nothing is cut mid-word.
    func iphoneCaption(_ storage: IPhoneStorage, videos: Int64) -> some View {
        let photos = "Photos and videos \(formatBytes(storage.photos))"
        let apps = "Apps \(formatBytes(storage.apps))"
        let move = "\(formatBytes(videos)) of videos to move"
        let options = videos > 0 ? ["\(photos) · \(apps) · \(move)", "\(apps) · \(move)", move, photos] : ["\(photos) · \(apps)", photos]
        return ViewThatFits(in: .horizontal) {
            ForEach(options, id: \.self) { Text($0).lineLimit(1).fixedSize(horizontal: true, vertical: false) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Ballast \(model.updates.current)")  // disabled: it only says which version this is
                Divider()
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
