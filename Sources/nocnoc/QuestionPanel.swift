import AppKit
import SwiftUI
import NocnocCore

/// Floating frosted-glass panels for questions (AskUserQuestion and ask_user),
/// one per waiting request.
///
/// The glass is an NSVisualEffectView with `.behindWindow` blending: macOS
/// blurs whatever is behind the panel (other apps, the desktop). The window
/// itself is borderless and clear, so only the rounded glass card shows.
/// `.nonactivatingPanel` lets it float and take typing without pulling you
/// out of the app you're in.
@MainActor
final class QuestionPanels: NSObject, NSWindowDelegate {
    static let shared = QuestionPanels()

    static let cornerRadius: CGFloat = 18
    static let width: CGFloat = 400

    private var panels: [UUID: NSPanel] = [:]
    /// Panels closed by us (answered/ended) vs. by the user.
    private var closingProgrammatically: Set<UUID> = []

    func show(_ request: PendingRequest) {
        guard panels[request.id] == nil, let questions = request.event.questions else { return }

        let model = QuestionModel(questions: questions)
        let id = request.id
        let view = QuestionCard(
            event: request.event, model: model, start: Date(), deadline: request.deadline,
            onSend: { AppState.shared.answerQuestion(id, model.answers) },
            onHandBack: { AppState.shared.answerInEditor(id) },
            onDismiss: { AppState.shared.answer(id, .released) }
        )

        let hosting = NSHostingView(rootView: view)
        // Measure the card's natural height. (Don't set sizingOptions to
        // .preferredContentSize: then fittingSize reports 0 and the panel is
        // created 0×0, i.e. invisible.)
        let measured = hosting.fittingSize.height
        let size = NSSize(width: Self.width, height: measured > 50 ? measured : 320)

        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier(id.uuidString)

        // Glass card: blur what's behind the window, clipped to a rounded rect.
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .popover          // adapts to light/dark; frosted and translucent
        glass.blendingMode = .behindWindow
        glass.state = .active              // stay frosted even when nocnoc isn't the active app
        glass.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        glass.autoresizingMask = [.width, .height]
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)
        panel.contentView = glass

        // Keyboard: 1-9 pick an option, Esc hands the question back.
        panel.onKey = { event in
            guard let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) else { return false }
            return model.choose(number: digit)
        }
        panel.onCancel = { AppState.shared.answerInEditor(id) }

        position(panel, index: panels.count)
        panels[id] = panel
        appear(panel)
    }

    func focus(_ id: UUID) {
        guard let panel = panels[id] else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// The request ended (answered, timed out, withdrawn): fade the panel away.
    func close(_ id: UUID) {
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
            AppState.shared.answer(id, .released)
        }
    }

    // MARK: - Window helpers

    /// Fade in while sliding down a few points.
    private func appear(_ panel: NSPanel) {
        let final = panel.frame
        panel.alphaValue = 0
        panel.setFrame(final.offsetBy(dx: 0, dy: 10), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
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

    /// A stretchable rounded-rect mask: the corners stay round at any size.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Borderless panels refuse key status by default; we need it for typing.
/// It also routes unhandled keys (digits) and Esc back to us.
private final class KeyablePanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
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
            ForEach(Array(model.questions.enumerated()), id: \.offset) { index, q in
                QuestionBlock(index: index, question: q, model: model, onSubmit: send)
                if index < model.questions.count - 1 {
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                }
            }
            footer
        }
        .padding(18)
        .frame(width: QuestionPanels.width, alignment: .leading)
        .overlay(   // thin bright edge: what makes the card read as glass
            RoundedRectangle(cornerRadius: QuestionPanels.cornerRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : .primary.opacity(hovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : .primary.opacity(0.10), lineWidth: 1))
    }
}
