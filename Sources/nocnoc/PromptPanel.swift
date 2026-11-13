import AppKit
import SwiftUI
import NocnocCore

/// Floating frosted-glass prompt cards, one per waiting request: permission
/// prompts (Allow / Deny) and questions (AskUserQuestion, ask_user). This is
/// the only place nocnoc asks you anything; there's no macOS notification
/// alongside, which used to land on top of the card and compete with it.
///
/// Cards never grab keyboard focus when they appear. You might be typing in
/// your editor, and stray keys (or an Enter) must not answer a prompt. Your
/// first click on a card focuses it and also counts as a click.
@MainActor
final class PromptPanels: NSObject, NSWindowDelegate {
    static let shared = PromptPanels()

    static let width: CGFloat = 400

    private var panels: [UUID: NSPanel] = [:]
    private var events: [UUID: AgentEvent] = [:]
    /// Cards that have been on screen at least once (they chime only the first time).
    private var announced: Set<UUID> = []
    /// Panels closed by us (answered/ended) vs. by the user.
    private var closingProgrammatically: Set<UUID> = []

    /// Tallest the scrolling middle of a card may get: the screen minus the
    /// card's fixed header/footer and some breathing room.
    static var maxBodyHeight: CGFloat {
        max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 240)
    }

    func show(_ request: PendingRequest) {
        guard panels[request.id] == nil else { return }
        let id = request.id
        let panel: GlassPanel

        if request.event.kind == .question, let questions = request.event.questions {
            let model = QuestionModel(questions: questions)
            panel = makePanel(id, QuestionCard(
                event: request.event, model: model, start: Date(), deadline: request.deadline,
                onSend: { AppState.shared.answerQuestion(id, model.answers) },
                onHandBack: { AppState.shared.answerInEditor(id) },
                onDismiss: { AppState.shared.answer(id, .released) }))
            // 1-9 pick an option (once you've clicked into the card).
            panel.onKey = { event in
                guard let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) else { return false }
                return model.choose(number: digit)
            }
        } else {
            panel = makePanel(id, PermissionCard(
                event: request.event, start: Date(), deadline: request.deadline,
                onAllow: { AppState.shared.answer(id, .decided(.allow)) },
                onDeny: { AppState.shared.answer(id, .decided(.deny)) },
                onHandBack: { AppState.shared.answerInEditor(id) }))
        }
        panel.onCancel = { AppState.shared.answerInEditor(id) }   // Esc

        position(panel, index: panels.count)
        panels[id] = panel
        events[id] = request.event
        if !AppState.shared.showsCard(request.event) {
            Log.info("card \(id.uuidString.prefix(8)) waiting: you're in the editor")
        }
        refreshVisibility()
    }

    /// Show or hide every card per Presence: hook prompts wait hidden while
    /// you're in the editor (you can answer them there) and appear when you
    /// leave it. Called when a card is added and when the front app changes.
    func refreshVisibility() {
        for (id, panel) in panels {
            guard let event = events[id] else { continue }
            let shouldShow = AppState.shared.showsCard(event)
            if shouldShow && !panel.isVisible {
                Log.info("card \(id.uuidString.prefix(8)) shown")
                appear(panel)
                if announced.insert(id).inserted { NSSound(named: "Glass")?.play() }
            } else if !shouldShow && panel.isVisible {
                Log.info("card \(id.uuidString.prefix(8)) hidden: you're in the editor")
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    panel.animator().alphaValue = 0
                }, completionHandler: { panel.orderOut(nil) })
            }
        }
    }

    private func makePanel<Card: View>(_ id: UUID, _ card: Card) -> GlassPanel {
        // Measure the card's natural height first. (Don't set sizingOptions to
        // .preferredContentSize: fittingSize then reports 0, i.e. a 0×0 panel.)
        let measured = NSHostingView(rootView: card).fittingSize.height
        let panel = GlassPanel(size: NSSize(width: Self.width, height: measured > 50 ? measured : 320))
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        panel.setGlassContent(card.modifier(HeightReporter { [weak panel] h in
            guard h > 50 else { return }
            panel?.setHeightKeepingTop(h)
        }))
        return panel
    }

    /// Bring a card forward and give it the keyboard (you asked for it).
    func focus(_ id: UUID) {
        guard let panel = panels[id] else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// The request ended (answered, timed out, withdrawn): fade the card away.
    func close(_ id: UUID) {
        events.removeValue(forKey: id)
        announced.remove(id)
        guard let panel = panels.removeValue(forKey: id) else { return }
        closingProgrammatically.insert(id)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.close() })
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let raw = panel.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if closingProgrammatically.remove(id) == nil {
            panels.removeValue(forKey: id)
            events.removeValue(forKey: id)
            announced.remove(id)
            AppState.shared.answer(id, .released)
        }
    }

    // MARK: - Window helpers

    /// Fade in while sliding down a few points. Deliberately no makeKey().
    private func appear(_ panel: NSPanel) {
        let final = panel.frame
        panel.alphaValue = 0
        panel.setFrame(final.offsetBy(dx: 0, dy: 10), display: false)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
    }

    /// Top-right of the screen, below the menu bar; stacked if several are open.
    private func position(_ panel: NSPanel, index: Int) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let offset = CGFloat(index) * 24
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 14 - offset,
                                     y: screen.maxY - size.height - 10 - offset))
    }
}

// MARK: - Model

/// What you've picked so far. A class (not view @State) so the panel's key
/// handler can change it too.
@MainActor
final class QuestionModel: ObservableObject {
    let questions: [AgentEvent.Question]
    @Published var chosen: [Int: Set<String>] = [:]   // option labels, per question
    @Published var other: [Int: String] = [:]         // typed answer, per question

    init(questions: [AgentEvent.Question]) { self.questions = questions }

    var numbersEnabled: Bool { questions.count == 1 }

    func toggle(_ index: Int, _ label: String) {
        let q = questions[index]
        var set = chosen[index, default: []]
        if q.multiSelect == true {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
            other[index] = ""
        }
        chosen[index] = set
    }

    /// Number keys pick options, only when there's a single question
    /// (with several, "2" would be ambiguous).
    func choose(number n: Int) -> Bool {
        guard numbersEnabled, let q = questions.first, n <= q.options.count else { return false }
        toggle(0, q.options[n - 1].label)
        return true
    }

    func setOther(_ index: Int, _ text: String) {
        other[index] = text
        // Typing an answer replaces a single-choice selection.
        if questions[index].multiSelect != true, !text.isEmpty { chosen[index] = [] }
    }

    /// Chosen labels (comma-joined, in offered order) plus any typed text.
    /// Questions with nothing chosen are left out, which keeps Send disabled.
    var answers: [String: String] {
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

    var isComplete: Bool { QuestionReply.isComplete(answers, for: questions) }
}

// MARK: - The card

struct QuestionCard: View {
    let event: AgentEvent
    @ObservedObject var model: QuestionModel
    let start: Date
    let deadline: Date
    let onSend: () -> Void
    let onHandBack: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // Header and footer stay put; the questions scroll once they'd be
            // taller than the screen.
            ScrollIfNeeded(maxHeight: PromptPanels.maxBodyHeight) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(model.questions.enumerated()), id: \.offset) { index, q in
                        QuestionBlock(index: index, question: q, model: model, onSubmit: send)
                        if index < model.questions.count - 1 {
                            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                        }
                    }
                }
            }
            footer
        }
        .padding(Glass.padding)
        .frame(width: PromptPanels.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(GlassEdge())
    }

    private func send() { if model.isComplete { onSend() } }

    private var header: some View {
        HStack(spacing: 8) {
            AgentBadge(agent: event.agent)
            if let project = event.project {
                Text(project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Countdown(start: start, deadline: deadline)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Hand back to VS Code (Esc)")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onHandBack) {
                    Text("Answer in VS Code").font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button(action: send) {
                    Text("Send")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Capsule().fill(Color.accentColor.opacity(model.isComplete ? 1 : 0.35)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isComplete)
            }
            Text(model.numbersEnabled ? "1–9 choose  ·  ⏎ send  ·  esc hand back" : "⏎ send  ·  esc hand back")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct QuestionBlock: View {
    let index: Int
    let question: AgentEvent.Question
    @ObservedObject var model: QuestionModel
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = question.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.caption2.weight(.semibold)).tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            if let context = question.context, !context.isEmpty {
                Text(context).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(question.question)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if question.multiSelect == true {
                Text("Choose any").font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { n, option in
                    OptionRow(number: model.numbersEnabled ? n + 1 : nil,
                              option: option,
                              multi: question.multiSelect == true,
                              selected: model.chosen[index, default: []].contains(option.label)) {
                        model.toggle(index, option.label)
                    }
                }
            }
            .padding(.top, 2)

            if question.offersOther {
                GlassField(placeholder: question.options.isEmpty ? "Your answer" : "Something else…",
                           text: Binding(get: { model.other[index] ?? "" }, set: { model.setOther(index, $0) }),
                           onSubmit: onSubmit)
            }
        }
    }
}

private struct OptionRow: View {
    let number: Int?
    let option: AgentEvent.Question.Option
    let multi: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                if let number {
                    Text("\(number)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(selected ? .white : .secondary)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Color.accentColor : .primary.opacity(0.08)))
                } else {
                    Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square")
                                            : (selected ? "largecircle.fill.circle" : "circle"))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.body.weight(selected ? .semibold : .regular))
                    if let d = option.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if selected && number != nil {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Glass.innerRadius, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : .primary.opacity(hovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Glass.innerRadius, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct GlassField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Glass.innerRadius, style: .continuous).fill(.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: Glass.innerRadius, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : .primary.opacity(0.10), lineWidth: 1))
    }
}


// MARK: - Permission card

struct PermissionCard: View {
    let event: AgentEvent
    let start: Date
    let deadline: Date
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onHandBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AgentBadge(agent: event.agent)
                if let project = event.project {
                    Text(project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Countdown(start: start, deadline: deadline)
                Button(action: onHandBack) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Hand back to VS Code (Esc)")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.toolName.map { "Wants to use \($0)" } ?? "Wants permission")
                    .font(.caption2.weight(.semibold)).tracking(0.8).textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(event.title).font(.title3.weight(.semibold))
            }

            CommandView(text: event.detail)

            HStack(spacing: 8) {
                Button("Answer in VS Code", action: onHandBack)
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Deny", action: onDeny)
                    .buttonStyle(CapsuleButtonStyle(destructive: true))
                // Never Allow what can't be read in full here. And no keyboard
                // shortcut: approving always takes a deliberate click.
                if !event.detailIsTruncated {
                    Button("Allow", action: onAllow)
                        .buttonStyle(CapsuleButtonStyle(prominent: true))
                }
            }
            if event.detailIsTruncated {
                Text("Too long to review here. Allow it in VS Code.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(Glass.padding)
        .frame(width: PromptPanels.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(GlassEdge())
    }
}
