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
                        HStack(spacing: 6) {
                            Text("Safe to reclaim").font(.headline)
                            Text(formatBytes(model.safeToReclaim)).font(Theme.mono(.headline).weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("See what's safe to remove")
                Rule()
                ForEach(summary.concerns.prefix(5), id: \.id) { c in
                    Button { open(c.id) } label: {
                        HStack {
                            Image(systemName: c.symbol).frame(width: 20)
                            Text(c.title)
                            Spacer()
                            Text(formatBytes(c.bytes)).font(Theme.mono()).foregroundStyle(Theme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(model.scanning ? "Scanning your disk…" : "No scan yet.").foregroundStyle(Theme.muted)
            }
            if let phone = model.iphone, let block = iphoneBlock(phone) {
                Rule()
                block
            }
            Rule()
            trash
            Rule()
            if UpdateRow.visible(model.updates) { UpdateRow(model: model) }
            footer
        }
        .padding(14)
        .frame(width: 320)
        .ballastSurface()
    }

    var freeSpace: some View {
        VStack(alignment: .leading, spacing: 4) {
            let fill = model.freeFraction < 0.1 ? Theme.danger : model.freeFraction < 0.2 ? Theme.review : Theme.ctaBg
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.bg3)
                    Capsule().fill(fill).frame(width: geo.size.width * min(1, max(0, 1 - model.freeFraction)))
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(formatBytes(model.free)) free of \(formatBytes(model.total))")
                    .font(Theme.mono(.callout))
                Spacer()
                // Here rather than in the footer, which has no room for it next to the buttons.
                if model.scanning {
                    Text("Scanning…").font(.caption).foregroundStyle(Theme.muted)
                } else if let at = model.summary?.scannedAt {
                    Text("Scanned \(relativeScanTime(at, now: Date()))").font(.caption).foregroundStyle(Theme.muted)
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
                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                    }
                    Text("Unlock it and tap Trust").font(.caption).foregroundStyle(Theme.muted).padding(.leading, 28)
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
                        Text("\(formatBytes(storage.free)) free").font(Theme.mono()).foregroundStyle(Theme.muted)
                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
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
        .font(.caption).foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var trash: some View {
        HStack {
            Image(systemName: "trash").frame(width: 20)
            Text("Trash")
            Spacer()
            if let detail = trashDetail {
                Text(detail).font(Theme.mono()).foregroundStyle(Theme.muted)
            }
            Button("Empty") { Task { await model.emptyTrash() } }
                .buttonStyle(DangerButtonStyle(outline: true))
                .controlSize(.small)
                .disabled(model.trash == .empty)
        }
    }

    /// The size when known, "Empty" when it is, an item count when only that is known, nothing when Ballast can't tell.
    var trashDetail: String? {
        switch model.trash {
        case .empty: "Empty"
        case .full(let bytes?, _): formatBytes(bytes)
        case .full(nil, let items?): items == 1 ? "1 item" : "\(items) items"
        case .full(nil, nil), .unknown: nil
        }
    }

    var footer: some View {
        HStack {
            if model.scanning { ProgressView().controlSize(.small) }
            Spacer()
            Button("Scan now") { Task { await model.scanNow() } }.buttonStyle(LineButtonStyle()).controlSize(.small).disabled(model.scanning)
            Button("Open Ballast") { open(nil) }.buttonStyle(BrassButtonStyle()).controlSize(.small)
            Menu {
                Text("Ballast \(model.updates.current)")  // disabled: it only says which version this is
                Divider()
                Button(model.updates.phase == .checking ? "Checking…" : "Check for updates") { Task { await model.updates.checkNow() } }
                    .disabled(model.updates.phase.busy)
                Button("Settings…") { Windows.shared.showSettings(model) }
                Button("Go Quiet…") { goQuiet(model) }
                Rule()
                Button("Quit Ballast") { NSApp.terminate(nil) }
            } label: { Image(systemName: "gearshape").foregroundStyle(Theme.accent) }
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
