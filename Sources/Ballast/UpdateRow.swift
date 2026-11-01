import BallastCore
import SwiftUI

/// Where an update is offered: progress, the Update button with a What's new link, or the result of a check.
struct UpdateRow: View {
    let model: AppModel

    /// Whether there is anything to show, so the popover can leave the row out when idle.
    static func visible(_ updates: UpdateCheck) -> Bool { updates.available != nil || updates.phase != .idle }

    var body: some View {
        let updates = model.updates
        VStack(alignment: .leading, spacing: 6) {
            switch updates.phase {
            case .checking:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }.font(.callout)
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloading Ballast \(updates.available?.version ?? "") — \(Int(fraction * 100))%").font(.callout)
                    ProgressView(value: fraction).tint(Theme.ctaBg)
                }
            case .installing:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking and installing…") }.font(.callout)
            case .installed(let version):
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Ballast \(version) is in. Reopening…") }.font(.callout)
            default:
                if let release = updates.available { offer(release) }
                if case .upToDate(let version) = updates.phase {
                    Text("Ballast \(version) is up to date").font(.callout).foregroundStyle(Theme.muted)
                }
                if case .failed(let message) = updates.phase {
                    Text(message).font(.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func offer(_ release: UpdateCheck.Release) -> some View {
        HStack(spacing: 10) {
            if release.download != nil {
                Button("Update to \(release.version)") {
                    Task { await model.updates.install(isCleaning: { model.run?.phase == .running }) }
                }
                .buttonStyle(BrassButtonStyle()).controlSize(.small)
                Link("What's new", destination: release.url).font(.caption).foregroundStyle(Theme.accent)
            } else {
                Link("Ballast \(release.version) is out", destination: release.url).font(.callout).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// The Check for updates button, small and quiet; disabled while anything is in flight.
struct CheckForUpdatesButton: View {
    let model: AppModel

    var body: some View {
        Button(model.updates.phase == .checking ? "Checking…" : "Check for updates") {
            Task { await model.updates.checkNow() }
        }
        .buttonStyle(LineButtonStyle()).controlSize(.small)
        .disabled(model.updates.phase.busy)
    }
}
