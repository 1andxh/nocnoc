import AppKit
import UserNotifications
import NocnocCore

/// macOS notifications, for information only: "finished" and Claude's own
/// "needs you". One per agent session, replaced in place so they don't stack.
/// Prompts (permissions, questions) never use notifications: they're glass
/// cards in the app (PromptPanel.swift), where they can't be competed with.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    var onStatus: ((String) -> Void)?
    /// Sessions whose current notification is a "needs you" (main thread only).
    private var attentionIDs: Set<String> = []
    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        center.setNotificationCategories([])   // drop the old Allow/Deny categories
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.info("notification authorization granted=\(granted) error=\(error.map { "\($0)" } ?? "none")")
            self.refreshStatus()
        }
    }

    func refreshStatus() {
        center.getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "On"
            case .denied: text = "Off — enable in System Settings"
            case .notDetermined: text = "Not asked yet"
            @unknown default: text = "Unknown"
            }
            self.onStatus?(text)
        }
    }

    // MARK: - Posting

    func post(_ event: AgentEvent) {
        let content = baseContent(event)
        let id = Self.sessionID(event.agent, event.sessionID ?? event.id.uuidString)
        // Same id per session: a newer event replaces the older notification.
        if event.kind == .attention { attentionIDs.insert(id) } else { attentionIDs.remove(id) }
        add(id, content)
    }

    /// Remove a session's "needs you" notification once the prompt is answered.
    /// Leaves "finished" notifications alone.
    func clearAttention(agent: String, sessionID: String?) {
        guard let sessionID else { return }
        let id = Self.sessionID(agent, sessionID)
        guard attentionIDs.remove(id) != nil else { return }
        center.removeDeliveredNotifications(withIdentifiers: [id])
        Log.info("cleared \(id.prefix(16)): answered")
    }

    private static func sessionID(_ agent: String, _ session: String) -> String { "\(agent)-\(session)" }

    private func baseContent(_ event: AgentEvent) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = event.project.map { "\($0) — \(event.title)" } ?? event.title
        content.body = event.body
        content.sound = .default
        content.threadIdentifier = event.sessionID ?? event.agent
        if let dir = event.projectDir { content.userInfo["projectDir"] = dir }
        return content
    }

    private func add(_ id: String, _ content: UNMutableNotificationContent) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            Log.info("notification \(id.prefix(16)) \(error.map { "failed: \($0)" } ?? "posted")")
        }
    }

    // MARK: - Delegate

    // Show banners even if nocnoc happens to be the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // Clicking a notification takes you to that project in VS Code.
        let dir = response.notification.request.content.userInfo["projectDir"] as? String
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { Editor.focus(projectDir: dir) }
        }
        completionHandler()
    }
}

enum Editor {
    static let vscodeBundleID = "com.microsoft.VSCode"

    /// Opening a folder in VS Code focuses the window that already has it open
    /// (or opens one). Without a folder, just bring VS Code forward.
    static func focus(projectDir: String?) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vscodeBundleID) else {
            Log.info("VS Code not found; nothing to focus")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let dir = projectDir, FileManager.default.fileExists(atPath: dir) {
            NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
    }
}
