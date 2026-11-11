import SwiftUI
import NocnocCore

@main
struct NocnocApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: state)
        } label: {
            if state.waiting.isEmpty {
                Image(systemName: state.away ? "bell.badge.fill" : "bell.slash")
            } else {
                // Something is waiting for you.
                Label("\(state.waiting.count)", systemImage: "exclamationmark.bubble.fill")
                    .labelStyle(.titleAndIcon)
            }
        }
        // .window: a popover-like window with real SwiftUI content, instead of a system menu.
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.stop() }
    }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if state.serverStatus != "Listening" { problem("Server: \(state.serverStatus)", action: nil) }
            if state.notificationStatus.hasPrefix("Off") {
                problem("Notifications are off for nocnoc", action: ("Open Settings", {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }))
            }
            if !state.waiting.isEmpty { waiting }
            recent
            footer
        }
        .padding(16)
        .frame(width: 360)
        .background(GlassBackground())
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(state.away ? Color.accentColor.opacity(0.18) : .primary.opacity(0.07))
                Image(systemName: state.away ? "bell.badge.fill" : "bell.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.away ? Color.accentColor : .secondary)
            }
            .frame(width: 36, height: 36)
            .animation(.easeOut(duration: 0.15), value: state.away)

            VStack(alignment: .leading, spacing: 2) {
                Text("nocnoc").font(.headline)
                Text(state.away ? "Away: prompts come to you here" : "At desk: prompts stay in VS Code")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Away", isOn: $state.away)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("Away: send agent prompts to this Mac")
        }
    }

    private func problem(_ text: String, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action {
                Button(action.0, action: action.1).buttonStyle(CapsuleButtonStyle())
            }
        }
        .glassCard(padding: 10)
    }

    // MARK: Waiting

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Waiting for you", count: state.waiting.count)
            ForEach(state.waiting) { request in
                WaitingCard(request: request, state: state)
            }
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Recent", count: nil)
            if state.events.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Nothing yet. Agent activity shows up here.")
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(state.events.prefix(6)) { RecentRow(event: $0) }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                Toggle("Open at login", isOn: Binding(get: { state.openAtLogin }, set: { state.setOpenAtLogin($0) }))
                Toggle("Record raw payloads (debug)", isOn: $state.recordPayloads)
                Divider()
                Button("Send test notification") { state.sendTestNotification() }
                Button("Open log") { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.log)) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")

            HStack(spacing: 5) {
                Circle().fill(state.serverStatus == "Listening" ? Color.green : Color.red).frame(width: 6, height: 6)
                Text(state.serverStatus == "Listening" ? "Ready" : "Not running")
            }
            .font(.caption).foregroundStyle(.secondary)

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int?
    init(_ title: String, count: Int?) { self.title = title; self.count = count }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.8)
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
    }
}

// MARK: - Waiting card

private struct WaitingCard: View {
    let request: PendingRequest
    @ObservedObject var state: AppState

    private var event: AgentEvent { request.event }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentBadge(agent: event.agent)
                if let project = event.project {
                    Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Countdown(start: event.at, deadline: request.deadline)
            }

            if event.kind == .question {
                Text(event.questions?.first?.question ?? event.title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Answer in VS Code") { state.answerInEditor(request.id) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Answer…") { QuestionPanels.shared.focus(request.id) }
                        .buttonStyle(CapsuleButtonStyle(prominent: true))
                }
            } else {
                Text(event.title).font(.callout.weight(.semibold))
                CommandView(text: event.detail)
                HStack(spacing: 8) {
                    Button("VS Code") { state.answerInEditor(request.id) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .help("Hand this back to the prompt in VS Code")
                    Spacer()
                    Button("Deny") { state.answer(request.id, .decided(.deny)) }
                        .buttonStyle(CapsuleButtonStyle(destructive: true))
                    // Never Allow what can't be read in full here.
                    if !event.detailIsTruncated {
                        Button("Allow") { state.answer(request.id, .decided(.allow)) }
                            .buttonStyle(CapsuleButtonStyle(prominent: true))
                    }
                }
                if event.detailIsTruncated {
                    Text("Too long to review here. Allow it in VS Code.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .glassCard()
    }
}

/// The full command, monospaced and selectable; scrolls when it's long.
private struct CommandView: View {
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
    }

    private var content: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Recent row

private struct RecentRow: View {
    let event: AgentEvent
    @State private var hovering = false

    private var icon: (name: String, tint: Color) {
        switch event.kind {
        case .finished: return ("checkmark.circle.fill", .green)
        case .attention: return ("bell.fill", .orange)
        case .permission: return ("lock.shield.fill", .accentColor)
        case .question: return ("questionmark.bubble.fill", .purple)
        case .activity, .other: return ("circle.fill", .gray)
        }
    }

    var body: some View {
        Button {
            Editor.focus(projectDir: event.projectDir)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon.name)
                    .font(.system(size: 13))
                    .foregroundStyle(icon.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.callout).lineLimit(1)
                    Text([event.project, event.body.split(separator: "\n").first.map(String.init)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Self.ago(event.at)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(event.projectDir.map { "Open \($0) in VS Code" } ?? "")
    }

    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }
}
