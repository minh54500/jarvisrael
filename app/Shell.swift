import AppKit

/// Mini-terminal de l'onglet Dev : une commande à la fois, dans le dossier choisi, avec ton shell (zsh,
/// tes alias et ton PATH). Le résultat s'affiche en direct ; Stop l'interrompt (comme ⌃C).
/// Pas de clavier pour le programme : une commande qui attend une réponse reçoit « fin de saisie ».
@MainActor
final class Shell: ObservableObject {
    static let shared = Shell()

    @Published var command = ""
    @Published private(set) var output: [String] = []
    @Published private(set) var running = false
    @Published private(set) var lastExit: Int32?
    @Published private(set) var folder: URL
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "shell.recent") ?? []

    private var history: [String] = UserDefaults.standard.stringArray(forKey: "shell.history") ?? []
    private var cursor: Int?
    private var process: Process?
    private var partial = ""
    private var started = Date()
    private static let maxLines = 600

    private init() {
        let saved = UserDefaults.standard.string(forKey: "shell.folder") ?? ""
        var dir: ObjCBool = false
        folder = !saved.isEmpty && FileManager.default.fileExists(atPath: saved, isDirectory: &dir) && dir.boolValue
            ? URL(fileURLWithPath: saved) : FileManager.default.homeDirectoryForCurrentUser
    }

    var folderName: String { folder.path == NSHomeDirectory() ? "~" : folder.lastPathComponent }

    func setFolder(_ url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: "shell.folder")
        recent.removeAll { $0 == url.path }
        recent.insert(url.path, at: 0)
        recent = Array(recent.prefix(8))
        UserDefaults.standard.set(recent, forKey: "shell.recent")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = folder
        panel.message = "Dossier où lancer les commandes"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }

    /// Ouvre une vraie fenêtre du Terminal dans ce dossier.
    func openInTerminal() {
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        ws.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// ↑ / ↓ : les commandes précédentes.
    func browse(_ step: Int) {
        guard !history.isEmpty else { return }
        let i = max(0, min(history.count, (cursor ?? history.count) + step))
        cursor = i
        command = i < history.count ? history[i] : ""
    }

    func clear() { output = []; lastExit = nil }

    func run() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !running else { return }
        history.removeAll { $0 == cmd }
        history.append(cmd)
        history = Array(history.suffix(60))
        UserDefaults.standard.set(history, forKey: "shell.history")
        cursor = nil
        command = ""
        if cmd == "clear" { return clear() }
        if cmd == "cd" || cmd.hasPrefix("cd ") { return changeDirectory(String(cmd.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }

        append(line: "$ " + cmd)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", cmd]  // interactif + connexion : tes alias, nvm, PATH…
        p.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = "0"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { Shell.shared.receive(text) } }
        }
        p.terminationHandler = { p in
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { Shell.shared.finished(status, pipe) } }
        }
        do { try p.run() } catch {
            append(line: "✗ Impossible de lancer la commande.")
            return
        }
        process = p
        running = true
        lastExit = nil
        started = Date()
    }

    /// Stop : comme ⌃C, puis plus fort si la commande résiste.
    func stop() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if p.isRunning { p.terminate() } }
    }

    private func changeDirectory(_ arg: String) {
        let raw = arg.isEmpty ? "~" : arg
        let expanded = (raw as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded)
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.standardizedFileURL.path, isDirectory: &dir), dir.boolValue else {
            return append(line: "✗ Dossier introuvable : \(raw)")
        }
        setFolder(url.standardizedFileURL)
        append(line: "→ \(folder.path)")
    }

    private func receive(_ text: String) {
        partial += text
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        for l in lines { append(line: l) }
    }

    private func finished(_ status: Int32, _ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        if !partial.isEmpty { append(line: partial); partial = "" }
        running = false
        process = nil
        lastExit = status
        if status != 0 { append(line: "✗ Code de sortie \(status)") }
        Store.shared.shellFinished(ok: status == 0, seconds: Date().timeIntervalSince(started))
    }

    /// Une ligne propre : sans les codes de couleur, et seulement la fin pour les barres de progression (\r).
    private func append(line raw: String) {
        var l = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        while l.hasSuffix("\r") { l.removeLast() }
        if let r = l.lastIndex(of: "\r") { l = String(l[l.index(after: r)...]) }
        output.append(l)
        if output.count > Self.maxLines { output.removeFirst(output.count - Self.maxLines) }
    }
}
