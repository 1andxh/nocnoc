import AppKit
import SwiftUI

// Pieces shared by the question panel and the menu-bar popover.

/// Apple-style geometry. Corners are "continuous" (the squircle Apple uses
/// everywhere), and nested shapes are concentric:
/// inner radius = outer radius − the padding between them.
enum Glass {
    static let radius: CGFloat = 26      // windows (popover, question panel)
    static let padding: CGFloat = 16     // window edge -> content
    static let innerRadius: CGFloat = radius - padding   // cards, rows, fields: 10
}

/// The frosted glass behind a whole window: blurs whatever is behind it, and
/// is clipped to a continuous rounded rect. Behind-window blur is rendered by
/// the window server, which only respects `maskImage` (not layer masks), so
/// the mask is redrawn whenever the size changes.
final class GlassView: NSVisualEffectView {
    private var maskedSize: NSSize = .zero
    var radius: CGFloat = Glass.radius

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover            // adapts to light/dark; frosted and translucent
        blendingMode = .behindWindow
        state = .active                // stay frosted when nocnoc isn't the active app
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        guard bounds.size != maskedSize, bounds.width > 0, bounds.height > 0 else { return }
        maskedSize = bounds.size
        maskImage = Self.mask(size: bounds.size, radius: radius)
    }

    static func mask(size: NSSize, radius: CGFloat) -> NSImage {
        let path = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(origin: .zero, size: size)).cgPath
        return NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path).fill()
            return true
        }
    }
}

/// Borderless, floating, non-activating panel that can still take keys
/// (for typing and Esc). Clear background: only the glass shows.
final class GlassPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // A clear window lets clicks on see-through pixels fall through to
        // whatever is behind it, and the behind-window blur isn't painted
        // into our pixels, so nearly the whole panel counted as see-through.
        // Setting this explicitly makes the window take clicks everywhere.
        ignoresMouseEvents = false
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Put SwiftUI content on glass inside this panel.
    @discardableResult
    func setGlassContent<Content: View>(_ view: Content) -> NSView {
        let glass = GlassView(frame: NSRect(origin: .zero, size: frame.size))
        glass.autoresizingMask = [.width, .height]
        // Also lay a practically invisible fill under the content, so every
        // point inside the glass is part of the window for hit-testing.
        let hosting = FirstClickHostingView(rootView: view.background(
            RoundedRectangle(cornerRadius: Glass.radius, style: .continuous).fill(Color.black.opacity(0.01))))
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)
        contentView = glass
        return hosting
    }

    /// Change height keeping the top edge where it is (things hang down from
    /// the menu bar), animated.
    func setHeightKeepingTop(_ height: CGFloat, animated: Bool = true) {
        guard abs(frame.height - height) > 0.5 else { return }
        var f = frame
        f.origin.y = f.maxY - height
        f.size.height = height
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(f, display: true)
            }
        } else {
            setFrame(f, display: true)
        }
        invalidateShadow()
    }
}

/// nocnoc is rarely the active app. By default AppKit spends the first click
/// on an inactive window just focusing it; accept it as a real click instead.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reports the SwiftUI content's height so the window can follow it.
struct HeightReporter: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(GeometryReader { geo in
            Color.clear
                .onAppear { onChange(geo.size.height) }
                .onChange(of: geo.size.height) { _, h in onChange(h) }
        })
    }
}

/// The thin light edge that makes a glass window read as glass.
struct GlassEdge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Glass.radius, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1)
    }
}

/// Capsule buttons: `prominent` is filled with the accent colour.
struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(prominent ? .semibold : .medium))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : (destructive ? Color.red : Color.primary))
            .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.primary.opacity(prominent ? 0 : 0.08), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

extension View {
    /// A slightly lighter rounded panel sitting on the glass.
    func glassCard(radius: CGFloat = Glass.innerRadius, padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
}

/// Small coloured tag naming the agent.
struct AgentBadge: View {
    let agent: String

    private var tint: Color {
        switch agent {
        case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": return Color(red: 0.36, green: 0.55, blue: 0.95)
        default: return .gray
        }
    }

    private var name: String {
        switch agent {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(name).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.18)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// Ring + m:ss until the question goes back to VS Code.
struct Countdown: View {
    let start: Date
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = max(deadline.timeIntervalSince(start), 1)
            let left = max(deadline.timeIntervalSince(context.date), 0)
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(.primary.opacity(0.12), lineWidth: 2)
                    Circle().trim(from: 0, to: left / total)
                        .stroke(left < 30 ? Color.orange : Color.accentColor,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                Text(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("After this, the question goes back to VS Code")
        }
    }
}

/// The full command, monospaced and selectable; scrolls when it's long.
struct CommandView: View {
    let text: String

    private var isLong: Bool {
        text.count > 360 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 6
    }

    var body: some View {
        Group {
            if isLong {
                ScrollView { content }.frame(height: 120)
            } else {
                content
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.06)))
    }

    private var content: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
