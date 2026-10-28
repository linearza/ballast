import BallastCore
import SwiftUI

struct MainWindowRoot: View {
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if model.selection == SafeView.id {
                SafeView(model: model)
            } else if let id = model.selection {
                ConcernDetail(model: model, concernID: id)
            } else if model.scanning && model.reports.isEmpty {
                ProgressView("Scanning your disk…")
            } else {
                Text("Choose a concern").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(item: Binding(get: { model.run }, set: { model.run = $0 })) { state in
            ConfirmSheet(model: model, state: state)
        }
        .sheet(item: Binding(get: { model.permission }, set: { model.permission = $0 })) { info in
            PermissionsSheet(info: info) { model.permission = nil }
        }
        .sheet(isPresented: Binding(get: { model.firstRun }, set: { _ in })) {
            FirstRunSheet(model: model)
        }
        .task {
            if model.reports.isEmpty && !model.firstRun { await model.scanNow() }
        }
    }
}

struct Sidebar: View {
    let model: AppModel

    /// Reports in section order, plus Large files, which only appears as a report once started.
    func rows(_ section: ConcernSection) -> [(id: String, title: String, symbol: String, bytes: Int64?)] {
        Providers.all.filter { $0.section == section }.compactMap { p in
            if let r = model.report(p.id) {
                return r.items.isEmpty ? nil : (p.id, p.title, p.symbol, r.total)
            }
            return p.needsUserStart ? (p.id, p.title, p.symbol, nil) : nil
        }
    }

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
            HStack {
                Label("Safe to reclaim", systemImage: "checkmark.seal")
                Spacer()
                Text(formatBytes(model.reports.reduce(0) { $0 + $1.reclaimable })).monospacedDigit().foregroundStyle(.secondary)
            }
            .tag(SafeView.id)
            ForEach(ConcernSection.allCases, id: \.self) { section in
                let rows = rows(section)
                if !rows.isEmpty {
                    SwiftUI.Section {
                        ForEach(rows, id: \.id) { row in
                            HStack {
                                Label(row.title, systemImage: row.symbol)
                                Spacer()
                                if model.scanningIDs.contains(row.id) {
                                    ProgressView().controlSize(.mini)
                                } else if let bytes = row.bytes {
                                    Text(formatBytes(bytes)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .tag(row.id)
                        }
                    } header: {
                        HStack {
                            Text(section.rawValue)
                            Spacer()
                            // Nothing measured yet (Large files before it's started): no total rather than "Zero KB".
                            if rows.contains(where: { $0.bytes != nil }) {
                                Text(formatBytes(rows.reduce(0) { $0 + ($1.bytes ?? 0) })).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(formatBytes(model.free)) free").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Scan all") { Task { await model.scanNow() } }.disabled(model.scanning)
            }
            .padding(10)
        }
    }
}
