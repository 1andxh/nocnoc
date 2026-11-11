import SwiftUI
import NocnocCore

@main
struct NocnocApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            if state.waiting.isEmpty {
                Image(systemName: state.away ? "bell.badge.fill" : "bell.slash")
            } else {
                // Something is waiting for you.
                Label("\(state.waiting.count)", systemImage: "exclamationmark.bubble.fill")
                    .labelStyle(.titleAndIcon)
            }
        }
        .menuBarExtraStyle(.menu)
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

struct MenuContent: View {
    @ObservedObject var state: AppState

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        Toggle("Away — notify me", isOn: $state.away)

        if !state.waiting.isEmpty {
            Divider()
            Text("Waiting for you")
            ForEach(state.waiting) { request in
                // A submenu per request: the full command is readable here even
                // when the notification had to cut it short.
                let wrapped = Self.wrap(request.event.detail)
                let fullyShown = !wrapped.truncated && !request.event.detailIsTruncated
                Menu("\(request.event.project ?? request.event.agent) — \(request.event.toolName ?? "tool")") {
                    ForEach(Array(wrapped.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                    Divider()
                    if request.event.kind == .question {
                        Button("Answer…") { QuestionPanels.shared.focus(request.id) }
                    } else {
                        // Same rule as the notification: never Allow what you can't read in full here.
                        if fullyShown {
                            Button("Allow") { state.answer(request.id, .decided(.allow)) }
                        } else {
                            Text("Too long to review here — answer in the editor")
                        }
                        Button("Deny") { state.answer(request.id, .decided(.deny)) }
                    }
                    Button("Answer in VS Code") { state.answerInEditor(request.id) }
                }
            }
        }

        Divider()

        if state.events.isEmpty {
            Text("No agent activity yet")
        } else {
            Text("Recent")
            ForEach(state.events.prefix(8)) { event in
                Button("\(Self.time.string(from: event.at))  \(event.project ?? event.agent) — \(event.title)") {
                    Editor.focus(projectDir: event.projectDir)
                }
            }
        }

        Divider()

        Text("Server: \(state.serverStatus)")
        Text("Notifications: \(state.notificationStatus)")
        if state.notificationStatus.hasPrefix("Off") {
            Button("Open Notification Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
        Button("Send test notification") { state.sendTestNotification() }
        Button("Open log") { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.log)) }
        Toggle("Open at login", isOn: Binding(get: { state.openAtLogin }, set: { state.setOpenAtLogin($0) }))
        Toggle("Record raw payloads (debug)", isOn: $state.recordPayloads)

        Divider()

        Button("Quit nocnoc") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Menu items don't wrap, so split long text into ~70-char lines.
    static func wrap(_ text: String, width: Int = 70, maxLines: Int = 40) -> (lines: [String], truncated: Bool) {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(raw)
            repeat {
                lines.append(String(rest.prefix(width)))
                rest = rest.dropFirst(width)
            } while !rest.isEmpty
        }
        return lines.count <= maxLines ? (lines, false) : (Array(lines.prefix(maxLines - 1)) + ["…"], true)
    }
}
