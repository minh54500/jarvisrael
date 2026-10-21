import AppKit

/// Où s'ouvrent les nouvelles sessions Claude Code : VS Code (l'extension) ou l'app Claude (Claude Desktop).
/// Au choix dans les Réglages et dans Projets récents.
enum OpenIn: String, CaseIterable, Identifiable {
    case vscode, app
    var id: String { rawValue }
    var name: String { self == .vscode ? "VS Code" : "App Claude" }

    static var current: OpenIn { OpenIn(rawValue: UserDefaults.standard.string(forKey: "openIn") ?? "") ?? .vscode }
}

/// L'app Claude, par ses liens claude:// : une conversation normale, une session Claude Code dans un dossier
/// ou Cowork, avec ton message déjà écrit (tu le relis, puis Entrée). L'app demande de confirmer le dossier.
/// Elle ne sait pas rouvrir une ancienne session Claude Code : « Reprendre » reste dans VS Code.
@MainActor
enum ClaudeApp {
    static let bundle = "com.anthropic.claudefordesktop"

    enum Kind: String {
        case chat = "claude.ai/new", code = "code/new", cowork = "cowork/new"
        var name: String {
            switch self {
            case .chat: "Conversation"
            case .code: "Claude Code"
            case .cowork: "Cowork"
            }
        }
    }

    /// L'app installée pour de vrai : pas la copie de l'installeur (.dmg encore ouvert) ni celle de la Corbeille,
    /// que macOS choisirait sinon pour ouvrir les liens claude://.
    static var app: URL? {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundle).first {
            !$0.path.hasPrefix("/Volumes/") && !$0.path.contains("/.Trash/")
        }
    }

    static var installed: Bool { app != nil }

    /// Faux si l'app n'est pas installée : l'encoche dit quoi faire (finir l'installation, ou la télécharger).
    @discardableResult
    static func open(_ kind: Kind, prompt: String = "", folder: String? = nil) -> Bool {
        guard let app else {
            let onInstaller = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundle).contains { $0.path.hasPrefix("/Volumes/") }
            Store.shared.collapse()
            Store.shared.showToast(Toast(icon: "exclamationmark.triangle.fill", color: "#F7B32B", title: "App Claude",
                                         text: onInstaller ? "Pas encore installée : glisse Claude dans Applications (fenêtre de l'installeur)."
                                                           : "Pas installée sur ce Mac : je t'ouvre la page pour la télécharger."))
            if !onInstaller, let url = URL(string: "https://claude.ai/download") { NSWorkspace.shared.open(url) }
            return false
        }
        var query: [String] = []
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { query.append("q=" + encode(String(text.prefix(14_000)))) }  // l'app coupe vers 14 000 signes
        if let folder, kind == .code { query.append("folder=" + encode(folder)) }
        guard let url = URL(string: "claude://" + kind.rawValue + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))) else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Tout encodé sauf lettres, chiffres et -._~ : un « + » ou un « & » du message arrive tel quel dans l'app
    /// Claude (les liens vscode:// en demandent deux, voir Projects.start).
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
}
