import AppKit
import ServiceManagement
import SwiftUI

struct Session: Identifiable {
    let id: String
    var cwd: String
    var name: String
    var color: String
    var state: BotState = .idle
    var line = "Session ouverte"
    var history: [String] = []
    var updated = Date()
    var termProgram = ""
    var message = ""
}

struct Permission: Identifiable {
    let id = UUID()
    let session: String
    let title: String
    let detail: String
    let responder: Responder
    let at = Date()
}

enum Mode { case hidden, compact, expanded }
enum Panel: Equatable { case greeting, overview, empty, approval, finished, error, upload, choose, converting, result }

private let PALETTE = ["#FF6B5B", "#2DD4A7", "#F7B32B", "#A78BFA", "#38BDF8", "#F472B6"]

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var mode: Mode = .hidden
    @Published var view: Panel = .empty
    @Published var sessions: [Session] = []
    @Published var focus: String?
    @Published var permissions: [Permission] = []
    @Published var files: [URL] = []
    @Published var progress = 0.0
    @Published var progressLabel = ""
    @Published var result = ""
    @Published var resultOK = true
    @Published var dropTargeted = false

    let mochi = Mochi(now: CACurrentMediaTime())
    private(set) var minis: [String: Mochi] = [:]
    var notch = CGSize(width: 184, height: 32)
    var pointer = CGPoint(x: -999, y: -999)  // dans le repère du panneau (y vers le bas)

    private var hovering = false
    private var fileDragging = false
    private var pinUntil: Date?
    private var lastGreet = Date.distantPast
    private var lastActivity = Date()
    private var slaps: [Date] = []
    private var dizzyUntil: Date?
    private var mochiHoverSince: Date?
    private var ended = Set<String>()  // sessions fermées : on ignore leurs derniers événements
    private var resultFolder: URL?
    private var createdFiles: [URL] = []
    private var process: Process?

    // MARK: Géométrie (repère de l'island, en points)

    static let panelSize = CGSize(width: 760, height: 320)
    static let expandedWidth = 640.0
    /// Ouverture : ressort avec léger dépassement (la courbe --spr du prototype).
    static let openAnimation = Animation.spring(response: 0.48, dampingFraction: 0.74)
    /// Fermeture : plus courte, sans rebond.
    static let closeAnimation = Animation.spring(response: 0.34, dampingFraction: 1)

    /// Haut des cartes : juste sous la caméra, quelle que soit la hauteur de l'encoche.
    var cardTop: Double { notch.height + 4 }

    var viewHeight: Double {
        let base: Double = switch view {
        case .greeting: 150
        case .overview: 196
        case .empty: 150
        case .approval: 206
        case .finished, .error, .choose: 176
        case .upload: 176
        case .converting, .result: 150
        }
        return base + max(0, notch.height - 32)
    }

    var islandTarget: CGSize {
        switch mode {
        case .hidden: notch
        case .compact: CGSize(width: notch.width + 104, height: notch.height)
        case .expanded: CGSize(width: Self.expandedWidth, height: viewHeight)
        }
    }

    /// Place du Mochi (centre, hauteur du corps), repère de l'island.
    var mochiSlot: (x: Double, y: Double, hb: Double) {
        switch mode {
        case .hidden: return (27, notch.height / 2, 0)
        case .compact: return (27, notch.height / 2, 17)
        case .expanded:
            let h = viewHeight, mid = cardTop + (h - cardTop - 10) / 2
            switch view {
            case .greeting: return (320, cardTop + 54, 58)
            case .upload: return (140, mid, 50)
            case .converting: return (54, mid, 30)
            default: return (60, mid, 40)
            }
        }
    }

    /// Centre du Mochi dans le repère du panneau (pour le regard et le survol).
    var mochiCenterInPanel: CGPoint {
        let s = islandTarget, m = mochiSlot
        return CGPoint(x: Self.panelSize.width / 2 - s.width / 2 + m.x, y: m.y)
    }

    // MARK: Survol, clics, glisser

    func setHover(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            lastActivity = Date()
            if mode != .expanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard self.hovering, self.mode != .expanded else { return }
                    self.expandDefault()
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !self.hovering && !self.pinned { self.collapse() }
            }
        }
    }

    private var pinned: Bool {
        if !permissions.isEmpty && mode == .expanded && view == .approval { return true }
        if view == .choose || view == .converting || fileDragging { return true }
        if let pinUntil, Date() < pinUntil { return true }
        return false
    }

    private var defaultView: Panel { sessions.isEmpty ? .empty : .overview }

    func expandDefault() {
        if !permissions.isEmpty { return show(.approval) }
        if Date().timeIntervalSince(lastGreet) > 600 {
            lastGreet = Date()
            show(.greeting, sound: "greet")
            mochi.startGreeting()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                if self.view == .greeting && self.mode == .expanded { withAnimation(Self.openAnimation) { self.view = self.defaultView } }
            }
        } else {
            show(defaultView)
        }
    }

    func show(_ v: Panel, sound: String? = "open") {
        let wasExpanded = mode == .expanded
        guard !(wasExpanded && view == v) else { return }
        withAnimation(Self.openAnimation) {
            view = v
            mode = .expanded
        }
        if !wasExpanded, let sound { Sound.shared.play(sound) }
        if !wasExpanded { mochi.blink() }
    }

    func collapse() {
        let was = mode
        pinUntil = nil
        let target: Mode = sessions.isEmpty ? .hidden : .compact
        guard mode != target else { return }
        withAnimation(Self.closeAnimation) {
            mode = target
        }
        if was == .expanded { Sound.shared.play("close") }
        mochi.setMouth(0)
    }

    /// Appelé ~60 fois par seconde par le suivi de souris.
    func pointerMoved(to p: CGPoint, mochiCenter: CGPoint?) {
        pointer = p
        guard let c = mochiCenter, mode == .expanded else { mochiHoverSince = nil; return }
        if hypot(p.x - c.x, p.y - c.y) < 26 {
            if mochiHoverSince == nil { mochiHoverSince = Date(); mochi.blink(); Sound.shared.play("hover") }
            else if Date().timeIntervalSince(mochiHoverSince!) > 1.9 && mochi.state == .idle {
                mochiHoverSince = .distantFuture
                mochi.emote(.love, 2)
                Sound.shared.play("love")
            }
        } else { mochiHoverSince = nil }
    }

    func mochiTapped() {
        guard mode == .expanded else { return expandDefault() }
        let now = Date()
        slaps = slaps.filter { now.timeIntervalSince($0) < 1.7 } + [now]
        Sound.shared.play("slap")
        mochi.squash()
        if slaps.count >= 3 {
            slaps = []
            dizzyUntil = now.addingTimeInterval(3.3)
            Sound.shared.play("dizzy")
            refreshMochi()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                self.dizzyUntil = nil
                self.refreshMochi()
                self.mochi.blink()
            }
        } else {
            mochi.emote(.annoyed, 0.8)
            Sound.shared.play("annoyed")
        }
    }

    func setFileDrag(_ near: Bool) {
        if near && !fileDragging {
            fileDragging = true
            show(.upload, sound: "hover")
            mochi.setMouth(0.42)
        } else if !near && fileDragging {
            fileDragging = false
            // Laisse le temps au dépôt d'arriver (le bouton est relâché juste avant).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard self.view == .upload, !self.fileDragging else { return }
                self.mochi.setMouth(0)
                if !self.hovering { self.collapse() } else { self.show(self.defaultView, sound: nil) }
            }
        }
    }

    func dropped(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        fileDragging = false
        files = urls
        mochi.emote(.gulp, 0.6)
        mochi.setMouth(0)
        Sound.shared.play("gulp")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.show(.choose, sound: nil) }
    }

    // MARK: Événements Claude Code

    func handle(_ ev: [String: Any], _ responder: Responder?) {
        let event = ev["hook_event_name"] as? String ?? ""
        let sid = ev["session_id"] as? String ?? "inconnue"
        let cwd = ev["cwd"] as? String ?? NSHomeDirectory()
        lastActivity = Date()

        if event == "SessionStart" { ended.remove(sid) }
        guard !ended.contains(sid) else { responder?.close(); return }
        if event == "SessionEnd" {
            ended.insert(sid)
            sessions.removeAll { $0.id == sid }
            minis[sid] = nil
            for p in permissions where p.session == sid { p.responder.close() }
            permissions.removeAll { $0.session == sid }
            if focus == sid { focus = sessions.first?.id }
            refreshMochi()
            if mode == .compact && sessions.isEmpty { collapse() }
            return
        }

        var s = sessions.first { $0.id == sid } ?? newSession(sid, cwd)
        s.cwd = cwd
        s.updated = Date()
        if let term = ev["term_program"] as? String, !term.isEmpty { s.termProgram = term }

        switch event {
        case "SessionStart":
            s.state = .idle
            s.line = "Session ouverte"
        case "UserPromptSubmit":
            s.state = .working
            s.line = "« \(short(ev["prompt"] as? String ?? "", 70)) »"
            push(&s)
        case "PreToolUse":
            if s.state != .approval { s.state = .working }
            s.line = describe(ev["tool_name"] as? String ?? "", ev["tool_input"] as? [String: Any] ?? [:])
            push(&s)
        case "PostToolUse", "PostToolUseFailure":
            // Permission tranchée ailleurs (dans le terminal) : on la retire.
            for p in permissions where p.session == sid { p.responder.close() }
            permissions.removeAll { $0.session == sid }
            s.state = .working
            if event == "PostToolUseFailure" { s.line = "✗ " + s.line }
            if view == .approval && permissions.isEmpty && mode == .expanded { collapseSoon() }
        case "PermissionRequest":
            guard let responder else { break }
            let (title, detail) = permissionText(ev["tool_name"] as? String ?? "", ev["tool_input"] as? [String: Any] ?? [:])
            permissions.append(Permission(session: sid, title: title, detail: detail, responder: responder))
            s.state = .approval
            focus = sid
            store(s)
            alert(.approval, state: .approval)
            // Claude Code abandonne le hook après 120 s : on retire la demande avant.
            let id = permissions.last!.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 117) { self.expire(id) }
            return
        case "Notification":
            let type = ev["notification_type"] as? String ?? ""
            if type != "permission_prompt" && !permissions.contains(where: { $0.session == sid }) {
                s.state = .waiting
                s.line = ev["message"] as? String ?? "Claude attend ta réponse"
                Sound.shared.play("question")
            }
        case "Stop":
            s.state = .finished
            s.line = "Terminé"
            focus = sid
            store(s)
            if permissions.isEmpty && view != .choose && view != .converting {
                alert(.finished, state: .finished)
                pinUntil = Date().addingTimeInterval(5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                    if self.view == .finished && !self.hovering { self.collapse() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.settle(sid) }
            return
        case "StopFailure":
            s.state = .error
            s.message = (ev["error"] as? String) ?? (ev["message"] as? String) ?? "La réponse de Claude a échoué."
            focus = sid
            store(s)
            alert(.error, state: .error)
            pinUntil = Date().addingTimeInterval(8)
            return
        default:
            break
        }
        store(s)
        refreshMochi()
        if mode == .hidden && !sessions.isEmpty { withAnimation(Self.openAnimation) { mode = .compact } }
    }

    private func newSession(_ id: String, _ cwd: String) -> Session {
        let color = PALETTE[sessions.count % PALETTE.count]
        let m = Mochi(mini: true, bodyColor: color, now: CACurrentMediaTime())
        minis[id] = m
        if focus == nil { focus = id }
        return Session(id: id, cwd: cwd, name: URL(fileURLWithPath: cwd).lastPathComponent, color: color)
    }

    private func store(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        minis[s.id]?.setState(s.state)
    }

    private func push(_ s: inout Session) {
        s.history.append(s.line)
        if s.history.count > 6 { s.history.removeFirst() }
    }

    private func settle(_ sid: String) {
        guard var s = sessions.first(where: { $0.id == sid }), s.state == .finished else { return }
        s.state = .idle
        store(s)
        refreshMochi()
    }

    private func alert(_ v: Panel, state: BotState) {
        refreshMochi()
        if mode == .expanded && view == .approval && v != .approval && !permissions.isEmpty { return }
        show(v, sound: nil)
        Sound.shared.play(STYLES[state]?.sound ?? "blip")
    }

    private func collapseSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            if !self.permissions.isEmpty { return self.show(.approval, sound: nil) }
            if self.hovering { self.show(self.defaultView, sound: nil) } else { self.collapse() }
        }
    }

    private func expire(_ id: UUID) {
        guard let p = permissions.first(where: { $0.id == id }) else { return }
        p.responder.close()
        permissions.removeAll { $0.id == id }
        if permissions.isEmpty && view == .approval { collapseSoon() }
    }

    /// Réponse depuis l'encoche : "allow", "always" ou "deny".
    func answer(_ decision: String) {
        guard let p = permissions.first else { return }
        p.responder.reply(["permissionDecision": decision])
        permissions.removeFirst()
        if var s = sessions.first(where: { $0.id == p.session }) {
            s.state = decision == "deny" ? .idle : .working
            store(s)
        }
        Sound.shared.play(decision == "deny" ? "blip" : "approve")
        if decision != "deny" { mochi.emote(.happy, 0.9) }
        refreshMochi()
        collapseSoon()
    }

    func refreshMochi() {
        if let dizzyUntil, Date() < dizzyUntil { return mochi.setState(.dizzy) }
        let order: [BotState] = [.approval, .error, .waiting, .working, .finished]
        let states = Set(sessions.map(\.state))
        var st = order.first { states.contains($0) } ?? .idle
        if st == .idle && !sessions.isEmpty && Date().timeIntervalSince(lastActivity) > 600 { st = .sleeping }
        mochi.setState(st)
    }

    var focused: Session? { sessions.first { $0.id == focus } ?? sessions.first }
    var currentPermission: Permission? { permissions.first }
    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    // MARK: Aller à la session (VS Code, Terminal…)

    func jump(to s: Session) {
        let ws = NSWorkspace.shared
        let bundle: String
        switch s.termProgram {
        case "Apple_Terminal": bundle = "com.apple.Terminal"
        case "iTerm.app": bundle = "com.googlecode.iterm2"
        default: bundle = "com.microsoft.VSCode"
        }
        if let app = ws.urlForApplication(withBundleIdentifier: bundle) {
            let urls = bundle == "com.microsoft.VSCode" ? [URL(fileURLWithPath: s.cwd)] : []
            ws.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
        Sound.shared.play("blip")
        collapse()
    }

    func dismissCurrent() {
        if let f = focused, f.state == .finished || f.state == .error {
            var s = f
            s.state = .idle
            store(s)
            refreshMochi()
        }
        collapse()
    }

    // MARK: Conversion (moteur du Convertisseur)

    static var engine: (python: URL, script: URL)? {
        for base in ["~/Applications", "/Applications"] {
            let res = URL(fileURLWithPath: (base as NSString).expandingTildeInPath)
                .appendingPathComponent("Convertisseur.app/Contents/Resources")
            let py = res.appendingPathComponent("python/bin/python3"), script = res.appendingPathComponent("convert.py")
            if FileManager.default.fileExists(atPath: py.path) { return (py, script) }
        }
        return nil
    }

    var hasPDF: Bool { files.contains { $0.pathExtension.lowercased() == "pdf" } }

    func convert(_ action: String) {
        guard let engine = Self.engine else {
            result = "Installe d'abord l'app Convertisseur."
            resultOK = false
            return show(.result, sound: nil)
        }
        let prefs = UserDefaults(suiteName: "io.github.minh54500.convertisseur")
        var args = [engine.script.path, "--json"]
        switch action {
        case "merge": args.append("--merge")
        case "compress": args += ["--compress", prefs?.string(forKey: "compressLevel") ?? "medium"]
        default:
            args += ["--to", action, "-q", String(prefs?.object(forKey: "quality") as? Int ?? 82),
                     "-w", String(prefs?.object(forKey: "maxWidth") as? Int ?? 1600)]
        }
        if let out = prefs?.string(forKey: "outDir"), !out.isEmpty { args += ["--out-dir", out] }
        let urls = action == "merge"
            ? files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            : files
        args += urls.map(\.path)

        progress = 0
        progressLabel = files.count == 1 ? files[0].lastPathComponent : "\(files.count) fichiers"
        createdFiles = []
        resultFolder = nil
        show(.converting, sound: nil)

        let p = Process()
        p.executableURL = engine.python
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        process = p
        do { try p.run() } catch {
            result = "Le Convertisseur n'a pas pu démarrer."
            resultOK = false
            return show(.result, sound: nil)
        }
        var lastTick = 0
        DispatchQueue.global().async {
            let reader = pipe.fileHandleForReading
            var buffer = Data()
            while case let chunk = reader.availableData, !chunk.isEmpty {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let ev = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    DispatchQueue.main.async {
                        switch ev["type"] as? String {
                        case "done":
                            let i = ev["index"] as? Int ?? 0, total = max(1, ev["total"] as? Int ?? 1)
                            self.progress = Double(i) / Double(total)
                            if let dst = ev["dst"] as? String { self.createdFiles.append(URL(fileURLWithPath: dst)) }
                            if Int(self.progress * 10) > lastTick { lastTick = Int(self.progress * 10); Sound.shared.play("tick") }
                        case "summary":
                            self.result = ev["message"] as? String ?? ""
                            self.resultOK = (ev["errors"] as? Int ?? 0) == 0
                            if let out = ev["out"] as? String, !out.isEmpty { self.resultFolder = URL(fileURLWithPath: out) }
                        default: break
                        }
                    }
                }
            }
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.process = nil
                if self.result.isEmpty { self.result = "Le Convertisseur s'est arrêté."; self.resultOK = false }
                self.progress = 1
                Sound.shared.play(self.resultOK ? "approve" : "error")
                if self.resultOK { self.mochi.emote(.proud, 1.6) }
                self.show(.result, sound: nil)
                self.pinUntil = Date().addingTimeInterval(4)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                    if self.view == .result && !self.hovering { self.collapse() }
                }
            }
        }
    }

    func revealResult() {
        if let resultFolder { NSWorkspace.shared.activateFileViewerSelecting([resultFolder]) }
        else if !createdFiles.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(createdFiles.prefix(50))) }
        collapse()
    }

    func cancelFiles() {
        process?.terminate()
        files = []
        collapse()
    }

    // MARK: Réglages

    @Published var hooked = false
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    func refreshHooked() {
        DispatchQueue.global().async {
            let on = Bridge.runHookTool("--status").output == "branché"
            DispatchQueue.main.async { self.hooked = on }
        }
    }

    func setHooked(_ on: Bool) {
        if on {
            let alert = NSAlert()
            alert.messageText = "Brancher Encoche à Claude Code ?"
            alert.informativeText = """
                Encoche ajoute ses hooks dans ~/.claude/settings.json (une copie de sauvegarde est faite à côté). \
                Tes sessions apparaîtront dans l'encoche, et tu pourras autoriser ou refuser les actions de Claude d'ici.

                Si l'app n'est pas ouverte, Claude Code fonctionne exactement comme avant.
                Pense à quitter Coucou pendant que tu utilises Encoche, sinon les deux te demanderont les mêmes permissions.
                """
            alert.addButton(withTitle: "Brancher")
            alert.addButton(withTitle: "Annuler")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let r = Bridge.runHookTool(on ? "--install" : "--uninstall")
        hooked = r.ok && on
        Sound.shared.play(r.ok ? "approve" : "error")
        if r.ok && on { mochi.emote(.proud, 1.6) }
        if !r.ok {
            let alert = NSAlert()
            alert.messageText = "Ça n'a pas marché"
            alert.informativeText = r.output
            alert.runModal()
        }
    }

    func setLoginItem(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Textes

private func short(_ s: String, _ n: Int) -> String {
    let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    return one.count > n ? String(one.prefix(n - 1)) + "…" : one
}

private func fileName(_ input: [String: Any]) -> String {
    let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? (input["path"] as? String) ?? ""
    return URL(fileURLWithPath: path).lastPathComponent
}

func describe(_ tool: String, _ input: [String: Any]) -> String {
    switch tool {
    case "Bash": return "$ " + short(input["command"] as? String ?? "", 60)
    case "Edit", "MultiEdit": return "Modifie \(fileName(input))"
    case "Write": return "Écrit \(fileName(input))"
    case "Read": return "Lit \(fileName(input))"
    case "NotebookEdit": return "Modifie \(fileName(input))"
    case "Grep": return "Cherche « \(short(input["pattern"] as? String ?? "", 40)) »"
    case "Glob": return "Cherche \(short(input["pattern"] as? String ?? "", 40))"
    case "WebFetch": return "Lit une page web"
    case "WebSearch": return "Cherche sur le web : \(short(input["query"] as? String ?? "", 40))"
    case "Task", "Agent": return "Lance un agent : \(short(input["description"] as? String ?? "", 40))"
    case "TodoWrite": return "Met à jour sa liste de tâches"
    case "AskUserQuestion": return "Te pose une question"
    default:
        if tool.hasPrefix("mcp__") { return "Utilise \(tool.split(separator: "_").last.map(String.init) ?? tool)" }
        return tool
    }
}

private func permissionText(_ tool: String, _ input: [String: Any]) -> (String, String) {
    switch tool {
    case "Bash": return ("veut lancer une commande", input["command"] as? String ?? "")
    case "Edit", "MultiEdit", "Write", "NotebookEdit": return ("veut modifier un fichier", (input["file_path"] as? String) ?? fileName(input))
    case "WebFetch": return ("veut lire une page web", input["url"] as? String ?? "")
    case "WebSearch": return ("veut chercher sur le web", input["query"] as? String ?? "")
    default:
        let detail = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ("veut utiliser \(tool)", short(detail, 200))
    }
}
