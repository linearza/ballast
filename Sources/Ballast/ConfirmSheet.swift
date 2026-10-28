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
            Text(state.phase == .finished ? "Done" : "Remove from \(state.provider.title)?").font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(state.plan.refusals, id: \.itemID) { r in
                        let title = state.items.first { $0.id == r.itemID }?.title ?? r.itemID
                        Label("\(title): \(r.reason)", systemImage: "xmark.octagon").foregroundStyle(.red)
                    }
                    if state.phase == .confirm && !state.dangers.isEmpty { dangerBox }
                    ForEach(state.plan.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
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
            if state.phase == .finished {
                Text("Freed \(formatBytes(state.freed))").font(.headline)
                if state.trashed > 0 {
                    Text("Moved to Trash: \(formatBytes(state.trashed)), empty the Trash to free it")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                switch state.phase {
                case .confirm:
                    Button("Cancel") { model.run = nil }.keyboardShortcut(.cancelAction)
                    // Return only confirms routine removals; anything else takes a deliberate click.
                    if state.level == .routine {
                        removeButton.keyboardShortcut(.defaultAction)
                    } else {
                        removeButton.tint(state.level == .dangerous ? .red : nil)
                    }
                case .running:
                    ProgressView().controlSize(.small)
                case .finished:
                    if state.trashed > 0 { Button("Empty Trash") { Task { await model.emptyTrash() } } }
                    Button("Close") { model.run = nil }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    var removeButton: some View {
        Button("Remove · \(formatBytes(state.plan.expectedBytes))", role: state.level == .dangerous ? .destructive : nil) {
            Task { await model.execute(state) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!state.canRemove)
    }

    var dangerBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Read this first", systemImage: "exclamationmark.octagon.fill").font(.headline).foregroundStyle(.red)
            ForEach(state.dangers, id: \.self) { d in
                Text("• \(d)").fixedSize(horizontal: false, vertical: true)
            }
            Toggle("I understand, and want to remove these", isOn: Binding(get: { state.acknowledged }, set: { state.acknowledged = $0 }))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.4)))
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
                    if step.expectedBytes > 0 { Text(formatBytes(step.expectedBytes)).monospacedDigit().foregroundStyle(.secondary) }
                }
                HStack(alignment: .top) {
                    Text(step.kind.display)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    if case .copyToTerminal(let command) = step.kind {
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                if outcome == nil { undoNote }
                if let message = message { Text(message).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    var outcome: StepOutcome? { state.outcomes[step.id] }

    var undoNote: some View {
        let undo = step.kind.undo
        return Label(undo.label, systemImage: undo == .fromTrash ? "arrow.uturn.backward" : undo == .never ? "exclamationmark.circle" : "terminal")
            .font(.caption)
            .foregroundStyle(undo == .never ? Color.orange : Color.secondary)
    }

    var message: String? {
        switch outcome {
        case .failed(let why), .skipped(let why): why
        default: nil
        }
    }

    @ViewBuilder var status: some View {
        switch outcome {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .shown: Image(systemName: "terminal").foregroundStyle(.secondary)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
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
