import AppKit
import BallastCore
import SwiftUI

@MainActor @Observable final class RunState: Identifiable {
    enum Phase { case confirm, running, finished }
    let id = UUID()
    let provider: any Provider
    let items: [Item]
    let plan: Plan
    var phase = Phase.confirm
    var outcomes: [UUID: StepOutcome] = [:]
    var freed: Int64 = 0
    var trashed: Int64 = 0
    /// Ticked "I understand" for a dangerous plan.
    var acknowledged = false

    init(provider: any Provider, items: [Item], plan: Plan) {
        self.provider = provider
        self.items = items
        self.plan = plan
    }

    var level: Caution { caution(of: plan, items: items) }
    var dangers: [String] { dangerNotes(plan, items: items) }
    var canRemove: Bool { !plan.steps.isEmpty && (level != .dangerous || acknowledged) }

    /// Steps grouped by item, in plan order. Steps without an item group on their own.
    var groups: [(title: String?, steps: [Step])] {
        var out: [(String?, [Step])] = []
        for step in plan.steps {
            let title = step.itemID.flatMap { id in items.first { $0.id == id }?.title }
            if let last = out.last, last.0 == title, title != nil { out[out.count - 1].1.append(step) }
            else { out.append((title, [step])) }
        }
        return out
    }
}

struct ConfirmSheet: View {
    let model: AppModel
    let state: RunState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.phase == .finished ? "Done" : state.provider.id == "iphone" ? "Clean up your iPhone?" : "Remove from \(state.provider.title)?").font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(state.plan.refusals, id: \.itemID) { r in
                        let title = state.items.first { $0.id == r.itemID }?.title ?? r.itemID
                        Label("\(title): \(r.reason)", systemImage: "xmark.octagon").foregroundStyle(Theme.danger)
                    }
                    if state.phase == .confirm && !state.dangers.isEmpty { dangerBox }
                    ForEach(state.plan.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.review)
                    }
                    ForEach(Array(state.groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 6) {
                            if let title = group.title { Text(title).font(.headline) }
                            ForEach(group.steps) { step in StepRow(state: state, step: step) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.phase == .finished && state.provider.id != "iphone" {
                (Text("Freed ") + Text(formatBytes(state.freed)).font(Theme.mono(.headline)).foregroundStyle(Theme.accent)).font(.headline)
                if state.trashed > 0 {
                    Text("Moved to Trash: \(formatBytes(state.trashed)), empty the Trash to free it")
                        .foregroundStyle(Theme.muted)
                }
            }
            HStack {
                Spacer()
                switch state.phase {
                case .confirm:
                    Button("Cancel") { model.run = nil }.buttonStyle(LineButtonStyle()).keyboardShortcut(.cancelAction)
                    // Return only confirms routine removals; anything else takes a deliberate click.
                    if state.level == .routine {
                        removeButton.keyboardShortcut(.defaultAction)
                    } else {
                        removeButton
                    }
                case .running:
                    ProgressView().controlSize(.small)
                case .finished:
                    if state.trashed > 0 { Button("Empty Trash") { Task { await model.emptyTrash() } }.buttonStyle(LineButtonStyle()) }
                    Button("Close") { model.run = nil }.buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .ballastSurface()
    }

    var removeButton: some View {
        Button("\(state.provider.id == "iphone" ? "Go ahead" : "Remove") · \(formatBytes(state.plan.expectedBytes))", role: state.level == .dangerous ? .destructive : nil) {
            Task { await model.execute(state) }
        }
        .buttonStyle(BrassButtonStyle(danger: state.level == .dangerous))
        .disabled(!state.canRemove)
    }

    var dangerBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Read this first", systemImage: "exclamationmark.octagon.fill").font(.headline).foregroundStyle(Theme.danger)
            ForEach(state.dangers, id: \.self) { d in
                Text("• \(d)").fixedSize(horizontal: false, vertical: true)
            }
            Toggle("I understand, and want to remove these", isOn: Binding(get: { state.acknowledged }, set: { state.acknowledged = $0 }))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.dangerBg))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.dangerLine))
    }
}

struct StepRow: View {
    let state: RunState
    let step: Step

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            status.frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(step.title)
                    Spacer()
                    if step.expectedBytes > 0 { Text(formatBytes(step.expectedBytes)).font(Theme.mono(.callout)).foregroundStyle(Theme.muted) }
                }
                HStack(alignment: .top) {
                    Text(step.kind.display)
                        .font(Theme.mono(.caption))
                        .textSelection(.enabled)
                        .foregroundStyle(Theme.muted)
                    if case .copyToTerminal(let command) = step.kind {
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        .buttonStyle(LineButtonStyle())
                        .controlSize(.small)
                    }
                }
                if outcome == nil { undoNote }
                if let message = message { Text(message).font(.caption).foregroundStyle(Theme.danger) }
            }
        }
    }

    var outcome: StepOutcome? { state.outcomes[step.id] }

    var undoNote: some View {
        let undo = step.kind.undo
        let symbol = switch undo {
        case .fromTrash: "arrow.uturn.backward"
        case .never: "exclamationmark.circle"
        case .copiedFirst: "doc.on.doc"
        case .yourCall: "terminal"
        }
        return Label(undo.label, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(undo == .never ? Theme.review : Theme.muted)
    }

    var message: String? {
        switch outcome {
        case .failed(let why), .skipped(let why): why
        default: nil
        }
    }

    @ViewBuilder var status: some View {
        switch outcome {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .shown: Image(systemName: "terminal").foregroundStyle(Theme.muted)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.review)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
        case nil:
            if state.phase == .running && isCurrent { ProgressView().controlSize(.mini) } else { Image(systemName: "circle").foregroundStyle(.tertiary) }
        }
    }

    var isCurrent: Bool { state.plan.steps.first { state.outcomes[$0.id] == nil }?.id == step.id }
}

extension StepKind {
    var firstPath: URL? {
        switch self {
        case .trash(let urls): urls.first
        case .truncate(let url): url
        case .unloadLoginItem(_, let plist): plist
        default: nil
        }
    }
}
