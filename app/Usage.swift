import AppKit

/// Jauge d'usage de l'abonnement Claude : % utilisé de la session de 5 h et de la semaine, et quand ça
/// repart à zéro. Claude Code donne ces chiffres à chaque réponse ; on lui pose une toute petite question
/// (modèle Haiku, quelques tokens) toutes les 15 min quand tu es devant le Mac et que Claude est branché.
@MainActor
final class Usage: ObservableObject {
    static let shared = Usage()

    struct Window: Equatable {
        var used: Double  // 0…1
        var resets: Date
    }

    @Published private(set) var fiveHour: Window?
    @Published private(set) var week: Window?
    @Published private(set) var updated: Date?
    private var running = false
    private var timer: Timer?
    private var warned: Date?

    private init() {}

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Usage.shared.refreshIfActive() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.refreshIfActive() }
    }

    /// Au survol de l'encoche : si les chiffres ont plus de 10 min.
    func refreshIfStale() {
        if Date().timeIntervalSince(updated ?? .distantPast) > 10 * 60 { refresh() }
    }

    private func refreshIfActive() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 10 * 60, Store.shared.hooked else { return }
        refresh()
    }

    func refresh() {
        guard !running else { return }
        running = true
        Claude.run(prompt: "ok", system: "Réponds seulement : ok", stream: true) { lines in
            for line in lines {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      o["type"] as? String == "rate_limit_event",
                      let windows = (o["rate_limit_info"] as? [String: Any])?["unifiedWindows"] as? [String: Any] else { continue }
                func window(_ k: String) -> Window? {
                    guard let w = windows[k] as? [String: Any], let u = w["utilization"] as? Double else { return nil }
                    return Window(used: u, resets: Date(timeIntervalSince1970: w["resetsAt"] as? Double ?? 0))
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Usage.shared.update(window("five_hour"), window("seven_day")) }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { Usage.shared.running = false } }
        }
    }

    private func update(_ five: Window?, _ seven: Window?) {
        fiveHour = five ?? fiveHour
        week = seven ?? week
        updated = Date()
        // 80 % de la session utilisée : le bonhomme prévient (une fois par session de 5 h).
        if let f = five, f.used >= 0.8, warned != f.resets {
            warned = f.resets
            let at = f.resets.formatted(date: .omitted, time: .shortened)
            Store.shared.showToast(Toast(icon: "gauge.with.dots.needle.67percent", color: "#F5A524",
                                         title: "\(Int(f.used * 100)) % de ta session Claude", text: "repart à zéro à \(at)"))
        }
    }
}

/// Petites requêtes à Claude Code en ligne de commande (`claude -p`), isolées : sans tes réglages ni tes hooks
/// (elles n'apparaissent pas comme une session dans l'encoche), sans outils, sans historique.
enum Claude {
    /// Où est `claude` : demandé une fois à ton shell (nvm, ~/.local/bin, Homebrew…).
    nonisolated(unsafe) private static var path: String?

    nonisolated static var executable: String? {
        if let path { return path }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        p.waitUntilExit()
        path = found.hasPrefix("/") ? found : nil
        return path
    }

    /// Lance la requête en arrière-plan ; `done` reçoit les lignes de la sortie (texte, ou JSON si `stream`).
    nonisolated static func run(prompt: String, system: String, model: String = "haiku", stream: Bool = false,
                                done: @escaping @Sendable ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let exe = executable else { return done([]) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            var args = ["-p", "--setting-sources", "project", "--model", model, "--no-session-persistence",
                        "--tools", "", "--system-prompt", system]
            if stream { args += ["--output-format", "stream-json", "--verbose"] }
            p.arguments = args + ["--", prompt]  // « -- » : un texte qui commence par « - » n'est pas lu comme une option
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env["ENCOCHE_INTERNAL"] = "1"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return done([]) }
            // Jamais plus de 90 s : sinon l'action resterait « en cours » pour toujours.
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) { if p.isRunning { p.terminate() } }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            done(stream ? text.split(separator: "\n").map(String.init) : [text.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }
}
