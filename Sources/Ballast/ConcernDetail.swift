import BallastCore
import SwiftUI

struct ConcernDetail: View {
    let model: AppModel
    let concernID: String

    var provider: (any Provider)? { model.provider(concernID) }
    var report: ConcernReport? { model.report(concernID) }
    var items: [Item] { (report?.items ?? []).sorted { $0.bytes > $1.bytes } }
    var checked: Set<String> { model.checked[concernID] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if report != nil {
                table
                Divider()
                bottomBar
            } else if provider?.needsUserStart == true {
                largeFilesIntro
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(provider?.title ?? "")
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let report {
                VStack(alignment: .leading) {
                    Text(formatBytes(report.total)).font(.title2.monospacedDigit())
                    Text("Safe to reclaim: \(formatBytes(report.reclaimable))").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let provider, let report {
                ForEach(provider.extraActions(report.items)) { action in
                    Button(action.title) { Task { await model.prepare(concern: concernID, ids: [action.id]) } }
                }
            }
            Button("Rescan") { Task { await model.scanNow(only: [concernID]) } }
                .disabled(model.scanning)
        }
        .padding(14)
    }

    var table: some View {
        Table(items) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(
                    get: { checked.contains(item.id) },
                    set: { on in
                        var set = checked
                        if on { set.insert(item.id) } else { set.remove(item.id) }
                        model.checked[concernID] = set
                    }))
                .labelsHidden()
            }
            .width(24)
            TableColumn("Name") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    if let detail = item.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            TableColumn("Status") { item in
                HStack(spacing: 4) {
                    ForEach(item.badges.sorted { $0.label < $1.label }, id: \.self) { b in
                        Text(b.label)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(b.meansInUse ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15)))
                    }
                }
            }
            TableColumn("Risk") { item in
                Text(item.risk.label).foregroundStyle(item.risk.color)
            }
            .width(90)
            TableColumn("Size") { item in
                if item.isLocked {
                    if model.measuring.contains(item.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Measure…") { Task { await model.measureLocked(concern: concernID, item: item) } }
                            .help("Locked: macOS protects this folder. Measuring may ask for access.")
                    }
                } else {
                    Text((item.sizeIsPartial ? "≥ " : "") + formatBytes(item.bytes)).monospacedDigit()
                }
            }
            .width(90)
        }
    }

    var bottomBar: some View {
        let chosen = items.filter { checked.contains($0.id) }
        return HStack {
            Button("Select safe") { model.checked[concernID] = selectSafe(items) }
            Button("Select none") { model.checked[concernID] = [] }.disabled(chosen.isEmpty)
            Spacer()
            Button(removeLabel(count: chosen.count, bytes: chosen.reduce(0) { $0 + $1.bytes })) {
                Task { await model.prepare(concern: concernID, ids: chosen.map(\.id)) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty)
        }
        .padding(12)
    }

    var largeFilesIntro: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder").font(.largeTitle).foregroundStyle(.secondary)
            Text("Looks through Documents, Downloads, Desktop and Movies for files over 500 MB. macOS will ask once for each folder.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Scan these folders") { Task { await model.scanNow(only: [concernID]) } }
                .disabled(model.scanning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Risk {
    var color: Color {
        switch self {
        case .regenerable: .green
        case .review: .orange
        case .yourData: .red
        }
    }
}

extension Badge {
    var label: String {
        switch self {
        case .isDefault: "default"
        case .pinned(let by): "pinned by \(by.joined(separator: ", "))"
        case .running: "running"
        case .mergedPR: "merged PR"
        case .openPR: "open PR"
        case .uncommitted(let n): "\(n) uncommitted"
        case .unpushed(let n): "\(n) unpushed"
        case .orphaned: "orphaned"
        case .lastUsed(let d): "last used \(d.formatted(.dateTime.month(.abbreviated).year()))"
        case .locked: "locked"
        case .selectedByXcodeSelect: "selected by xcode-select"
        case .inICloud: "in iCloud"
        }
    }
}
