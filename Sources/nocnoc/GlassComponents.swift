import AppKit
import SwiftUI

// Pieces shared by the question panel and the menu-bar popover.

/// Frosted glass: blurs whatever is behind the window.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
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
    func glassCard(radius: CGFloat = 12, padding: CGFloat = 12) -> some View {
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
