import AppKit
import UserNotifications
import NocnocCore

/// macOS notifications.
///
/// Info events (finished, needs you, questions): one notification per agent
/// session, replaced in place so they don't stack.
/// Permission requests: one per request, with Allow / Deny buttons, removed
/// as soon as the request ends however it ends.
/// Questions get no notification: their floating panel is the alert.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Category {
        static let permission = "permission"                 // Allow + Deny
        static let permissionDenyOnly = "permission-deny-only" // command too long to show in full
    }
    enum Action {
        static let allow = "allow"
        static let deny = "deny"
    }

    var onStatus: ((String) -> Void)?
    /// Sessions whose current notification is a "needs you" (main thread only).
    private var attentionIDs: Set<String> = []
    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self

        // .authenticationRequired: macOS only runs Allow when the Mac is unlocked.
        let allow = UNNotificationAction(identifier: Action.allow, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Action.deny, title: "Deny", options: [.destructive])
        // .customDismissAction: we get told when you close the notification,
        // so we can hand the request back to VS Code instead of leaving it hanging.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.permission, actions: [allow, deny],
                                   intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.permissionDenyOnly, actions: [deny],
                                   intentIdentifiers: [], options: [.customDismissAction]),
        ])

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

    func postPermission(_ request: PendingRequest) {
        let event = request.event
        let content = baseContent(event)
        content.interruptionLevel = .timeSensitive
        content.userInfo["requestID"] = request.id.uuidString
        if event.bodyIsTruncated {
            // Never offer Allow for something you can't fully read here.
            content.categoryIdentifier = Category.permissionDenyOnly
            content.body += "\nToo long to show — open the nocnoc menu or VS Code to review."
        } else {
            content.categoryIdentifier = Category.permission
        }
        add(Self.permissionID(request.id), content)
    }

    func removePermission(_ id: UUID) {
        let nid = Self.permissionID(id)
        center.removeDeliveredNotifications(withIdentifiers: [nid])
        center.removePendingNotificationRequests(withIdentifiers: [nid])
    }

    private static func permissionID(_ id: UUID) -> String { "req-\(id.uuidString)" }

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
        let info = response.notification.request.content.userInfo
        let dir = info["projectDir"] as? String
        let requestID = (info["requestID"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let state = AppState.shared
                guard let id = requestID else {
                    // Info notification: clicking it just takes you there.
                    if action == UNNotificationDefaultActionIdentifier { Editor.focus(projectDir: dir) }
                    return
                }
                switch action {
                case Action.allow: state.answer(id, .decided(.allow))
                case Action.deny: state.answer(id, .decided(.deny))
                case UNNotificationDefaultActionIdentifier: state.answerInEditor(id)   // clicked the body
                case UNNotificationDismissActionIdentifier: state.answer(id, .released) // closed it
                default: break
                }
            }
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
