import AppKit

/// Mise à jour depuis l'app : Encoche connaît le dossier d'où elle a été compilée (EncocheSource, dans
/// Info.plist). Toutes les 6 h, elle regarde sur GitHub s'il y a du nouveau ; un clic récupère le code,
/// recompile et relance l'app (comme la commande d'installation).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var news: [String] = []   // titres des nouveautés (messages de commit)
    @Published private(set) var checking = false
    @Published private(set) var updating = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var problem: String?
    private var announced = UserDefaults.standard.string(forKey: "update.announced") ?? ""
    private var timer: Timer?

    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let c = (Bundle.main.object(forInfoDictionaryKey: "EncocheCommit") as? String ?? "").prefix(7)
        return c.isEmpty ? v : "\(v) (\(c))"
    }

    /// Le dossier git d'où vient l'app (~/.encoche chez tes potes, ton projet chez toi).
    var source: String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "EncocheSource") as? String, !s.isEmpty,
              FileManager.default.fileExists(atPath: s + "/.git") else { return nil }
        return s
    }

    func start() {
        guard source != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check() }
        }
    }

    func check() {
        guard let src = source, !checking, !updating else { return }
        checking = true
        problem = nil
        DispatchQueue.global(qos: .utility).async {
            let fetched = Self.git(src, ["fetch", "--quiet", "origin", "main"]) != nil
            let log = Self.git(src, ["log", "--format=%s", "-n", "20", "HEAD..origin/main"]) ?? ""
            let head = Self.git(src, ["rev-parse", "origin/main"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let titles = log.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Updater.shared.checked(fetched: fetched, titles: titles, head: head) }
            }
        }
    }

    private func checked(fetched: Bool, titles: [String], head: String) {
        checking = false
        lastCheck = Date()
        guard fetched else { problem = "Impossible de joindre GitHub (pas d'internet ?)."; return }
        news = titles
        // Une seule annonce par nouvelle version.
        if !titles.isEmpty && head != announced {
            announced = head
            UserDefaults.standard.set(head, forKey: "update.announced")
            Store.shared.showToast(Toast(icon: "arrow.down.circle.fill", color: "#34D399", title: "Nouvelle version d'Encoche",
                                         text: titles[0], opensUpdate: true))
        }
    }

    /// Récupère le code (sans écraser de modifs locales), puis recompile et relance l'app en arrière-plan.
    func update() {
        guard let src = source, !updating else { return }
        updating = true
        problem = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let pulled = Self.git(src, ["pull", "--ff-only", "--quiet", "origin", "main"]) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let u = Updater.shared
                    guard pulled else {
                        u.updating = false
                        u.problem = "La mise à jour n'a pas pu récupérer le code (modifs locales dans \(src) ?)."
                        return
                    }
                    // build.sh quitte Encoche : on le lance détaché, puis on rouvre l'app une fois compilée.
                    let log = NSHomeDirectory() + "/Library/Logs/Encoche-mise-a-jour.log"
                    let script = "( '\(src)/build.sh' && { open \"$HOME/Applications/Encoche.app\" || { sleep 2; open \"$HOME/Applications/Encoche.app\"; }; } ) > '\(log)' 2>&1 &"
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    p.arguments = ["-c", script]
                    try? p.run()
                }
            }
        }
    }

    nonisolated private static func git(_ dir: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
