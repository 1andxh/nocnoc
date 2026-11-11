import AppKit
import SwiftUI
import NocnocCore

/// Floating panels for AskUserQuestion, one per waiting question request.
///
/// NSPanel with .nonactivatingPanel: it floats above other apps and can take
/// keyboard input (for "Other…") without pulling you out of whatever app
/// you're in.
@MainActor
final class QuestionPanels: NSObject, NSWindowDelegate {
    static let shared = QuestionPanels()

    private var panels: [UUID: NSPanel] = [:]
    /// Panels closed by us (answered/ended) vs by you (the close button).
    private var closingProgrammatically: Set<UUID> = []

    func show(_ request: PendingRequest) {
        guard panels[request.id] == nil, let questions = request.event.questions else { return }

        let view = QuestionView(
            event: request.event, questions: questions, deadline: request.deadline,
            onSend: { answers in AppState.shared.answerQuestion(request.id, answers) },
            onAnswerInEditor: { AppState.shared.answerInEditor(request.id) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = request.event.title
        panel.titlebarAppearsTransparent = true
        panel.contentView = hosting
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier(request.id.uuidString)

        position(panel, index: panels.count)
        panels[request.id] = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func focus(_ id: UUID) {
        guard let panel = panels[id] else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// The request ended (answered, timed out, withdrawn): take the panel away.
    func close(_ id: UUID) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        closingProgrammatically.insert(id)
        panel.close()
    }

    // You clicked the close button: hand the question back to the editor.
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let raw = panel.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if closingProgrammatically.remove(id) == nil {
            panels.removeValue(forKey: id)
            AppState.shared.answer(id, .released)
        }
    }

    /// Top-right of the screen, stacked downwards if several are open.
    private func position(_ panel: NSPanel, index: Int) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let offset = CGFloat(index) * 28
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16 - offset,
                                     y: screen.maxY - size.height - 16 - offset))
    }
}

/// Non-activating panels refuse key status by default; we need it for typing.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - The panel's content

struct QuestionView: View {
    let event: AgentEvent
    let questions: [AgentEvent.Question]
    let deadline: Date
    let onSend: ([String: String]) -> Void
    let onAnswerInEditor: () -> Void

    @State private var chosen: [Int: Set<String>] = [:]   // option labels, per question
    @State private var other: [Int: String] = [:]         // typed "Other" answer, per question

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.project ?? event.agent).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(timerInterval: Date()...deadline, countsDown: true)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("After this, the question goes back to VS Code")
            }

            ForEach(Array(questions.enumerated()), id: \.offset) { index, q in
                questionBlock(index, q)
                if index < questions.count - 1 { Divider() }
            }

            HStack {
                Button("Answer in VS Code", action: onAnswerInEditor)
                Spacer()
                Button("Send") { onSend(answers) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!QuestionReply.isComplete(answers, for: questions))
            }
        }
        .padding(16)
        .padding(.top, 12)   // room for the transparent title bar
        .frame(width: 380)
    }

    @ViewBuilder
    private func questionBlock(_ index: Int, _ q: AgentEvent.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = q.header, !header.isEmpty {
                Text(header.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let context = q.context, !context.isEmpty {
                Text(context).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(q.question).font(.headline).fixedSize(horizontal: false, vertical: true)
            if q.multiSelect == true {
                Text("Choose any").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(q.options, id: \.label) { option in
                optionRow(index, q, option)
            }

            if q.offersOther {
                TextField(q.options.isEmpty ? "Your answer" : "Other…", text: Binding(
                    get: { other[index] ?? "" },
                    set: { text in
                        other[index] = text
                        // Typing an answer replaces a single-choice selection.
                        if q.multiSelect != true, !text.isEmpty { chosen[index] = [] }
                    }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func optionRow(_ index: Int, _ q: AgentEvent.Question, _ option: AgentEvent.Question.Option) -> some View {
        let multi = q.multiSelect == true
        let isOn = chosen[index, default: []].contains(option.label)
        return Button {
            var set = chosen[index, default: []]
            if multi {
                if isOn { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = [option.label]
                other[index] = ""
            }
            chosen[index] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: multi ? (isOn ? "checkmark.square.fill" : "square")
                                        : (isOn ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                    if let d = option.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What gets sent: chosen labels (comma-joined, in offered order) plus any
    /// typed text. Questions with nothing chosen are left out, which keeps
    /// Send disabled until everything is answered.
    private var answers: [String: String] {
        var out: [String: String] = [:]
        for (i, q) in questions.enumerated() {
            var parts: [String] = []
            let labels = QuestionReply.join(chosen[i, default: []], in: q)
            if !labels.isEmpty { parts.append(labels) }
            let typed = (other[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { parts.append(typed) }
            if !parts.isEmpty { out[q.question] = parts.joined(separator: ", ") }
        }
        return out
    }
}
