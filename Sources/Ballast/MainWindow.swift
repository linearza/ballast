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
            } else if model.selection == IPhoneDetail.id {
                IPhoneDetail(model: model)
            } else if let id = model.selection {
                ConcernDetail(model: model, concernID: id)
            } else if model.scanning && model.reports.isEmpty {
                ProgressView("Scanning your disk…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            } else {
                Text("Choose a concern").foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .tint(Theme.ctaBg)
        .foregroundStyle(Theme.text)
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
    func rows(_ section: ConcernSection) -> [(id: String, title: String, symbol: String, bytes: Int64?, note: String?)] {
        Providers.all.filter { $0.section == section }.compactMap { p in
            if let r = model.report(p.id) {
                // A connected iPhone is listed even when it's locked or has nothing to clean: the page says why.
                if let phone = r.iphone { return (p.id, phone.name, p.symbol, nil, nil) }
                return r.items.isEmpty ? nil : (p.id, p.title, p.symbol, r.total, nil)
            }
            return p.needsUserStart ? (p.id, p.title, p.symbol, nil, nil) : nil
        }
    }

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
            HStack {
                Label { Text("Safe to reclaim") } icon: { Image(systemName: "checkmark.seal").foregroundStyle(Theme.accent) }
                Spacer()
                Text(formatBytes(model.reports.reduce(0) { $0 + $1.reclaimable })).font(Theme.mono(.callout)).foregroundStyle(Theme.accent)
            }
            .tag(SafeView.id)
            .listRowBackground(model.selection == SafeView.id ? Theme.selection : Color.clear)
            ForEach(ConcernSection.allCases, id: \.self) { section in
                let rows = rows(section)
                if !rows.isEmpty {
                    SwiftUI.Section {
                        ForEach(rows, id: \.id) { row in
                            HStack {
                                Label { Text(row.title) } icon: { Image(systemName: row.symbol).foregroundStyle(Theme.accent) }
                                Spacer()
                                if model.scanningIDs.contains(row.id) {
                                    ProgressView().controlSize(.mini)
                                } else if let bytes = row.bytes {
                                    Text(formatBytes(bytes)).font(Theme.mono(.callout)).foregroundStyle(Theme.muted)
                                } else if let note = row.note {
                                    Text(note).lineLimit(1).foregroundStyle(Theme.muted)
                                }
                            }
                            .tag(row.id)
                            .listRowBackground(model.selection == row.id ? Theme.selection : Color.clear)
                        }
                    } header: {
                        HStack {
                            Text(section.rawValue.uppercased()).font(.caption.weight(.semibold)).tracking(0.6)
                            Spacer()
                            // Nothing measured yet (Large files before it's started): no total rather than "Zero KB".
                            if rows.contains(where: { $0.bytes != nil }) {
                                Text(formatBytes(rows.reduce(0) { $0 + ($1.bytes ?? 0) })).font(Theme.mono(.caption))
                            }
                        }
                    }
                }
            }
        }
        .ballastList(Theme.bg2)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(formatBytes(model.free)) free").font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                Button("Scan all") { Task { await model.scanNow() } }.buttonStyle(LineButtonStyle()).disabled(model.scanning)
            }
            .padding(10)
            .background(Theme.bg2)
        }
    }
}
