import BallastCore
import SwiftUI

/// Everything "Safe to reclaim" adds up, grouped by concern. Removing still goes through each concern's own
/// list and confirmation, with these items ticked.
struct SafeView: View {
    static let id = "safe"
    /// Leading and trailing inset shared by the page header, the section headers and the rows.
    static let inset: CGFloat = 14
    let model: AppModel

    var groups: [(report: ConcernReport, items: [Item])] { safeGroups(model.reports) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(formatBytes(groups.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.bytes } })).font(Theme.mono(.title).weight(.semibold)).foregroundStyle(Theme.accent)
                    Text("Regenerable and not in use: caches, old downloads and build output that come back when needed.")
                        .font(.callout).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(14)
            Rule()
            if groups.isEmpty {
                if model.scanning {
                    ProgressView("Scanning your disk…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Nothing safe to reclaim right now.").foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(groups, id: \.report.id) { group in
                            SwiftUI.Section {
                                ForEach(group.items) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                            if let detail = item.detail {
                                                Text(detail).font(Theme.mono(.caption)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                                            }
                                        }
                                        Spacer()
                                        Text(formatBytes(item.bytes)).font(Theme.mono(.callout)).foregroundStyle(Theme.muted)
                                    }
                                    .padding(.horizontal, Self.inset).padding(.vertical, 7)
                                }
                                Spacer().frame(height: 18)
                            } header: {
                                VStack(spacing: 0) {
                                    HStack {
                                        Label(group.report.title, systemImage: group.report.symbol).font(.headline)
                                        Text(formatBytes(group.items.reduce(0) { $0 + $1.bytes })).font(Theme.mono(.callout)).foregroundStyle(Theme.accent)
                                        Spacer()
                                        Button("Review and remove…") {
                                            model.checked[group.report.id] = Set(group.items.map(\.id))
                                            model.selection = group.report.id
                                        }
                                        .buttonStyle(DangerButtonStyle(outline: true))
                                        .controlSize(.small)
                                    }
                                    .padding(.horizontal, Self.inset).padding(.vertical, 10)
                                    Rule()
                                }
                                .background(Theme.bg)
                            }
                        }
                    }
                }
            }
        }
        .background(Theme.bg)
        .navigationTitle("Safe to reclaim")
    }
}
