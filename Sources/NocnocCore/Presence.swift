import Foundation

/// "Are you already where the agent's own prompt is?"
///
/// Agents show their prompt in the editor/terminal at the same time as our
/// hook, and the first answer wins. So while one of those apps is in front,
/// nocnoc keeps hook prompts held but hidden. Answer in the editor and the
/// card is withdrawn; switch away and it appears.
///
/// Frontmost app isn't proof you can *see* the prompt (other window, other
/// project), which is why this is a setting and why nothing is ever lost:
/// the prompt stays answerable in both places.
public enum Presence {
    /// Editors and terminals agents run in. VS Code's id is verified (nocnoc
    /// opens it by this id); the rest are the apps' standard ids.
    public static let editorBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",
        "com.vscodium",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
    ]

    public static func isEditor(_ bundleID: String?) -> Bool {
        bundleID.map(editorBundleIDs.contains) ?? false
    }

    /// Should this prompt's card be on screen right now?
    /// ask_user has no prompt in the editor (the card is the only way to
    /// answer it), so it always shows.
    public static func showsCard(for event: AgentEvent, editorFrontmost: Bool, quietInEditor: Bool) -> Bool {
        event.hookEvent == "ask_user" || !(quietInEditor && editorFrontmost)
    }

    /// Information notifications ("finished", "needs you") are pointless while
    /// you're looking at the editor.
    public static func notifies(editorFrontmost: Bool, quietInEditor: Bool) -> Bool {
        !(quietInEditor && editorFrontmost)
    }
}
