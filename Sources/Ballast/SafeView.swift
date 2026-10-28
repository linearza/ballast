import BallastCore
import SwiftUI

/// Everything "Safe to reclaim" adds up, grouped by concern. Removing still goes through each concern's own
/// list and confirmation, with these items ticked.
struct SafeView: View {
    static let id = "safe"
    let model: AppModel

    var groups: [(report: ConcernReport, items: [Item])] { safeGroups(model.reports) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(formatBytes(groups.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.bytes } })).font(.title2.monospacedDigit())
                    Text("Regenerable and not in use: caches, old downloads and build output that come back when needed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            Divider()
            if groups.isEmpty {
                if model.scanning {
                    ProgressView("Scanning your disk…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Nothing safe to reclaim right now.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    ForEach(groups, id: \.report.id) { group in
                        SwiftUI.Section {
                            ForEach(group.items) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                        if let detail = item.detail {
                                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    Spacer()
                                    Text(formatBytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            HStack {
                                Label(group.report.title, systemImage: group.report.symbol)
                                Text(formatBytes(group.items.reduce(0) { $0 + $1.bytes })).monospacedDigit().foregroundStyle(.secondary)
                                Spacer()
                                Button("Review and remove…") {
                                    model.checked[group.report.id] = Set(group.items.map(\.id))
                                    model.selection = group.report.id
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Safe to reclaim")
    }
}
