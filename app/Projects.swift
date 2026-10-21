import AppKit

/// Tes projets Claude Code récents et leurs sessions, lus dans ~/.claude/projects (l'historique que Claude
/// Code tient sur ton Mac) : reprendre une ancienne session, ou en ouvrir une nouvelle dans un projet.
@MainActor
final class Projects: ObservableObject {
    static let shared = Projects()

    struct Conversation: Identifiable, Equatable {
        let id: String       // identifiant de session Claude Code
        let title: String    // ta première demande
        let date: Date
    }

    struct Project: Identifiable, Equatable {
        let path: String
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
        var sessions: [Conversation]
        var id: String { path }
        var last: Date { sessions.first?.date ?? .distantPast }
    }

    @Published private(set) var list: [Project] = []
    @Published private(set) var loading = false

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Projects.shared.list = found
                    Projects.shared.loading = false
                }
            }
        }
    }

    /// Reprendre : VS Code s'ouvre sur le projet, puis sur la session.
    func resume(_ c: Conversation, in p: Project) {
        var s = Session(id: c.id, cwd: p.path, name: p.name, color: "#FF8BC4")
        s.entrypoint = "claude-vscode"
        Store.shared.openSession(s)
        Store.shared.collapse()
    }

    /// Nouvelle session dans ce dossier (avec un message déjà écrit si tu veux), dans VS Code ou l'app Claude.
    /// Faux si l'app voulue n'est pas là.
    @discardableResult
    func start(in path: String, prompt: String = "", place: OpenIn = .current) -> Bool {
        if place == .app {
            guard ClaudeApp.open(.code, prompt: prompt, folder: path) else { return false }
            Store.shared.collapse()
            return true
        }
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            Store.shared.collapse()
            Store.shared.showToast(Toast(icon: "exclamationmark.triangle.fill", color: "#F7B32B", title: "VS Code",
                                         text: "Pas installé sur ce Mac : choisis l'app Claude dans Réglages → Général."))
            return false
        }
        // Encodé deux fois : VS Code décode le lien une fois, puis l'extension relit la suite avec URLSearchParams
        // (sinon un « & » coupe le message et un « + » devient une espace).
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = URL(string: "vscode://anthropic.claude-code/open" + (text.isEmpty ? "" : "?prompt=" + ClaudeApp.encode(ClaudeApp.encode(text)))) else { return false }
        ws.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        func open(_ tries: Int) {  // le lien va à la fenêtre active : on attend que ce soit celle du projet
            if ws.frontmostApplication?.bundleIdentifier == "com.microsoft.VSCode" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ws.open(link) }
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { open(tries - 1) }
            }
        }
        open(40)
        Store.shared.collapse()
        return true
    }

    /// Reprendre dans le Terminal : `claude --resume` dans le dossier du projet.
    func resumeInTerminal(_ c: Conversation, in p: Project) {
        let cmd = "cd \(Self.shellQuote(p.path)) && claude --resume \(c.id)"
        let script = "tell application id \"com.apple.Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
        }
        Store.shared.collapse()
    }

    nonisolated private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Lecture de l'historique

    nonisolated private static func scan() -> [Project] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        var byPath: [String: [Conversation]] = [:]
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
                .prefix(6)
            for (file, date) in files {
                guard let (cwd, title) = head(file) else { continue }
                byPath[cwd, default: []].append(Conversation(id: file.deletingPathExtension().lastPathComponent, title: title, date: date))
            }
        }
        let temporary = ["/tmp", "/private/tmp", "/private/var/folders", "/var/folders", NSTemporaryDirectory()]
        return byPath.filter { p in fm.fileExists(atPath: p.key) && !temporary.contains { p.key == $0 || p.key.hasPrefix($0 + "/") || p.key.hasPrefix($0) && $0.hasSuffix("/") } }
            .map { Project(path: $0.key, sessions: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.last > $1.last }
            .prefix(10)
            .map { $0 }
    }

    /// Le dossier et la première vraie demande d'une session (en lisant seulement le début du fichier).
    nonisolated private static func head(_ file: URL) -> (String, String)? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        var cwd: String?, title: String?
        for line in data.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if cwd == nil, let c = o["cwd"] as? String { cwd = c }
            if title == nil, o["type"] as? String == "user", o["isMeta"] as? Bool != true,
               let m = o["message"] as? [String: Any] {
                let text = (m["content"] as? String)
                    ?? (m["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
                if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                   !t.hasPrefix("<"), !t.hasPrefix("Caveat:") {
                    title = String(t.replacingOccurrences(of: "\n", with: " ").prefix(80))
                }
            }
            if cwd != nil && title != nil { break }
        }
        guard let cwd else { return nil }
        return (cwd, title ?? "Session sans message")
    }
}
