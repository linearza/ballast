import AppKit
import BallastCore
import SwiftUI

/// The Connected iPhone concern: a storage summary like Settings › General › iPhone Storage, then the videos,
/// photos and apps that can go. It has its own view because the list is in two groups and the first isn't removed, but moved.
struct IPhoneDetail: View {
    let model: AppModel
    static let id = "iphone"

    var snapshot: IPhoneSnapshot? { model.report(Self.id)?.iphone ?? model.iphone }
    var items: [Item] { model.report(Self.id)?.items ?? [] }
    var checked: Set<String> { model.checked[Self.id] ?? [] }
    var media: [Item] { items.filter { $0.id.contains(".media.") }.sorted { $0.bytes > $1.bytes } }
    var apps: [Item] { items.filter { $0.id.contains(".app.") }.sorted { $0.bytes > $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot, snapshot.state == .ready {
                list(snapshot)
                Divider()
                bottomBar
            } else {
                message(snapshot)
            }
        }
        .navigationTitle("Connected iPhone")
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text(snapshot?.name ?? "iPhone").font(.title2)
                if let sub = snapshot?.subtitle, !sub.isEmpty { Text(sub).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            if let storage = snapshot?.storage {
                VStack(alignment: .trailing) {
                    Text(formatBytes(storage.free)).font(.title2.monospacedDigit())
                    Text("free").font(.callout).foregroundStyle(.secondary)
                }
            }
            Button("Rescan") { Task { await model.scanNow(only: [Self.id]) } }.disabled(model.scanning)
        }
        .padding(14)
    }

    // MARK: - States without a list

    func message(_ snapshot: IPhoneSnapshot?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: snapshot?.state == .toolsMissing ? "arrow.down.circle" : "lock.iphone").font(.largeTitle).foregroundStyle(.secondary)
            if model.scanningIDs.contains(Self.id) && snapshot == nil {
                ProgressView("Looking at your iPhone…")
            } else {
                Text(snapshot?.state.message ?? "No iPhone connected").multilineTextAlignment(.center).frame(maxWidth: 420)
                if snapshot?.state == .toolsMissing {
                    Text("Homebrew: brew install libimobiledevice ideviceinstaller").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    func list(_ snapshot: IPhoneSnapshot) -> some View {
        List {
            if let storage = snapshot.storage {
                StorageSummary(storage: storage).listRowSeparator(.hidden)
            }
            if !snapshot.missingTools.isEmpty {
                Label("\(snapshot.missingTools.joined(separator: " and ")) not found, so part of the list is missing. This build of Ballast is missing part of its iPhone tools; the download from the releases page includes them.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            SwiftUI.Section {
                if !snapshot.media.isEmpty {
                    Text("Camera roll: \(snapshot.media.summary)").font(.callout).foregroundStyle(.secondary)
                }
                if media.isEmpty {
                    Text("No videos over 20 MB or photos over 50 MB.").foregroundStyle(.secondary)
                }
                ForEach(media) { row($0) }
            } header: {
                Text("Videos and large photos").font(.headline)
            } footer: {
                Text("Moved to your Mac first, and deleted from the iPhone once the copy is checked.").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section {
                if apps.isEmpty { Text("No apps found.").foregroundStyle(.secondary) }
                ForEach(apps) { row($0) }
            } header: {
                Text("Apps").font(.headline)
            } footer: {
                Text(IPhoneStorage.appsNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func row(_ item: Item) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { checked.contains(item.id) },
                set: { on in
                    var set = checked
                    if on { set.insert(item.id) } else { set.remove(item.id) }
                    model.checked[Self.id] = set
                }))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(formatBytes(item.bytes)).monospacedDigit()
        }
    }

    var bottomBar: some View {
        let chosen = items.filter { checked.contains($0.id) }
        let moves = chosen.filter { $0.id.contains(".media.") }.count
        let uninstalls = chosen.count - moves
        let size = formatBytes(chosen.reduce(0) { $0 + $1.bytes })
        let label = switch (moves, uninstalls) {
        case (0, 0): "Nothing selected"
        case (let m, 0): "Move \(m) to Mac… · \(size)"
        case (0, let u): "Uninstall \(u) \(u == 1 ? "app" : "apps")… · \(size)"
        default: "Review \(chosen.count) items… · \(size)"
        }
        return HStack {
            Button("Select none") { model.checked[Self.id] = [] }.disabled(chosen.isEmpty)
            Spacer()
            Button(label) { Task { await model.prepare(concern: Self.id, ids: chosen.map(\.id)) } }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
        }
        .padding(12)
    }
}

/// The stacked bar of how an iPhone's storage is used, shared by the detail view and the menu.
struct StorageBar: View {
    let storage: IPhoneStorage
    var height: CGFloat = 16

    static func color(_ part: IPhoneStorage.Part) -> Color {
        switch part {
        case .photos: .orange
        case .apps: .blue
        case .system: .gray
        case .notVisible: .gray.opacity(0.4)
        case .free: .secondary.opacity(0.12)
        }
    }

    var body: some View {
        let parts = storage.parts
        let total = max(1, parts.reduce(0) { $0 + $1.bytes })
        let radius = height / 3
        let gaps = Double(max(0, parts.count - 1))  // the 1pt gaps between segments come out of the width
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(parts, id: \.part) { p in
                    Rectangle().fill(Self.color(p.part)).frame(width: max(0, (geo.size.width - gaps) * Double(p.bytes) / Double(total)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.secondary.opacity(0.3)))
        }
        .frame(height: height)
    }
}

/// A stacked bar of how the iPhone's storage is used, a legend, and what the bar can't tell.
struct StorageSummary: View {
    let storage: IPhoneStorage

    var body: some View {
        let parts = storage.parts
        return VStack(alignment: .leading, spacing: 8) {
            StorageBar(storage: storage)
            WrappingLayout(horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(parts, id: \.part) { p in
                    HStack(spacing: 5) {
                        Circle().fill(StorageBar.color(p.part)).overlay(Circle().strokeBorder(Color.secondary.opacity(0.4))).frame(width: 9, height: 9)
                        Text(p.part.rawValue)
                        Text(formatBytes(p.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .fixedSize()
                }
            }
            Text("Not visible over USB: " + IPhoneStorage.notVisibleNote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

/// Flows its subviews left to right and wraps them onto new lines when the row is full.
struct WrappingLayout: Layout {
    var horizontalSpacing: CGFloat = 16
    var verticalSpacing: CGFloat = 6

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += lineHeight + verticalSpacing; lineHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + horizontalSpacing
            lineHeight = max(lineHeight, s.height)
            maxX = max(maxX, x - horizontalSpacing)
        }
        return (frames, CGSize(width: maxX, height: y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(subviews, width: bounds.width)
        for (v, f) in zip(subviews, r.frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: .unspecified)
        }
    }
}
