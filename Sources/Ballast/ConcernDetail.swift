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
            Rule()
            if report != nil {
                table
                Rule()
                bottomBar
            } else if provider?.needsUserStart == true {
                largeFilesIntro
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .navigationTitle(provider?.title ?? "")
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let report {
                VStack(alignment: .leading) {
                    Text(formatBytes(report.total)).font(Theme.mono(.title2).weight(.semibold)).foregroundStyle(Theme.accent)
                    (Text("Safe to reclaim ").foregroundStyle(Theme.muted) + Text(formatBytes(report.reclaimable)).font(Theme.mono(.callout)).foregroundStyle(Theme.ok)).font(.callout)
                }
            }
            Spacer()
            if let provider, let report {
                ForEach(provider.extraActions(report.items)) { action in
                    Button(action.title) { Task { await model.prepare(concern: concernID, ids: [action.id]) } }.buttonStyle(LineButtonStyle())
                }
            }
            Button("Rescan") { Task { await model.scanNow(only: [concernID]) } }
                .buttonStyle(LineButtonStyle())
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
                        Text(detail).font(Theme.mono(.caption)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            TableColumn("Status") { item in
                HStack(spacing: 4) {
                    ForEach(item.badges.sorted { $0.label < $1.label }, id: \.self) { b in
                        Tag(text: b.label, color: b.meansInUse ? Theme.review : Theme.muted, tint: b.meansInUse ? Theme.tintReview : Theme.tintNeutral)
                    }
                }
            }
            TableColumn("Risk") { item in
                Tag(text: item.risk.label, color: item.risk.tagColor, tint: item.risk.tagTint)
            }
            .width(100)
            TableColumn("Size") { item in
                if item.isLocked {
                    if model.measuring.contains(item.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Measure…") { Task { await model.measureLocked(concern: concernID, item: item) } }
                            .help("Locked: macOS protects this folder. Measuring may ask for access.")
                    }
                } else {
                    Text((item.sizeIsPartial ? "≥ " : "") + formatBytes(item.bytes)).font(Theme.mono(.callout))
                }
            }
            .width(90)
        }
        .alternatingRowBackgrounds(.disabled)
        .ballastList()
    }

    var bottomBar: some View {
        let chosen = items.filter { checked.contains($0.id) }
        return HStack {
            Button("Select safe") { model.checked[concernID] = selectSafe(items) }.buttonStyle(LineButtonStyle())
            Button("Select none") { model.checked[concernID] = [] }.buttonStyle(LineButtonStyle()).disabled(chosen.isEmpty)
            Spacer()
            Button(removeLabel(count: chosen.count, bytes: chosen.reduce(0) { $0 + $1.bytes })) {
                Task { await model.prepare(concern: concernID, ids: chosen.map(\.id)) }
            }
            .buttonStyle(BrassButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty)
        }
        .padding(12)
        .background(Theme.bg2)
    }

    var largeFilesIntro: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder").font(.largeTitle).foregroundStyle(Theme.muted)
            Text("Looks through Documents, Downloads, Desktop and Movies for files over 500 MB. macOS will ask once for each folder.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Scan these folders") { Task { await model.scanNow(only: [concernID]) } }
                .buttonStyle(BrassButtonStyle())
                .disabled(model.scanning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Risk {
    var color: Color {
        switch self {
        case .regenerable: Theme.ok
        case .review: Theme.review
        case .yourData: Theme.danger
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
