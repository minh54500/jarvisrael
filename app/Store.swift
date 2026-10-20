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
    var entrypoint = ""  // "claude-vscode" : session de l'extension VS Code (onglet Claude Code)
    var tty = ""         // onglet du Terminal d'Apple où tourne la session (/dev/ttys003…)
    var message = ""
    var model = ""  // "claude-opus-5-5"… annoncé par Claude Code au démarrage de la session
    var turnStart: Date?    // début de la demande en cours
    var transcript = ""     // historique JSONL de la session (Claude Code), pour compter les tokens
    var transcriptOffset: UInt64 = 0  // sa taille au début de la demande
    var touched: [String] = []  // fichiers modifiés pendant cette demande
    var turn: Turn?         // bilan de la dernière demande terminée
    var todos: [Todo] = []  // la liste de tâches de Claude (outil TodoWrite)

    var plan: (done: Int, total: Int)? {
        todos.isEmpty ? nil : (todos.filter { $0.status == "completed" }.count, todos.count)
    }
    var currentTodo: Todo? { todos.first { $0.status == "in_progress" } }

    /// Où vit la session, pour les boutons « Voir dans … ».
    var place: String {
        if entrypoint == "claude-vscode" { return "VS Code" }
        switch termProgram {
        case "Apple_Terminal": return "le Terminal"
        case "iTerm.app": return "iTerm"
        default: return "VS Code"
        }
    }
}

/// Une tâche de la liste de Claude : « pending », « in_progress » ou « completed ».
struct Todo: Equatable {
    var content: String
    var status: String
    var activeForm: String
}

/// Ce que Claude a fait pendant une demande : fichiers modifiés, durée, lignes (git).
struct Turn {
    var files: [String]
    var seconds: Double
    var added: Int?
    var removed: Int?
    var output: Int?   // tokens écrits par Claude pendant la demande
    var context: Int?  // taille du contexte à la fin (tout ce que Claude relit à chaque message)

    var tokens: String? {
        guard let output else { return nil }
        let ctx = context.map { " · contexte \(Turn.short($0))" } ?? ""
        return "\(Turn.short(output)) tokens\(ctx)"
    }

    static func short(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
            : n >= 10_000 ? "\(n / 1000)k" : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    var text: String {
        let d = seconds < 60 ? "\(max(1, Int(seconds))) s" : "\(Int((seconds / 60).rounded())) min"
        if files.isEmpty { return "en \(d)" }
        return "\(files.count) fichier\(files.count > 1 ? "s" : "") en \(d)"
    }
}

/// Modèles proposés dans l'encoche. `arg` est ce qu'on passe à `/model`.
struct ClaudeModel: Identifiable {
    let arg: String
    let name: String
    var id: String { arg }

    static let all = [
        ClaudeModel(arg: "claude-fable-5-1", name: "Fable 5.1"),
        ClaudeModel(arg: "claude-opus-5-5", name: "Opus 5.5"),
        ClaudeModel(arg: "claude-sonnet-5-5", name: "Sonnet 5.5"),
        ClaudeModel(arg: "claude-haiku-5-5", name: "Haiku 5.5"),
    ]

    /// « claude-opus-5-5 » → « Opus 5.5 » (et « claude-sonnet-5-5[1m] » → « Sonnet 5.5 [1m] »).
    static func label(_ id: String) -> String {
        if let m = all.first(where: { $0.arg == id }) { return m.name }
        var rest: String = id.hasPrefix("claude-") ? String(id.dropFirst(7)) : id
        var suffix = ""
        if let b = rest.firstIndex(of: "[") { suffix = " " + String(rest[b...]); rest = String(rest[..<b]) }
        let parts: [String] = rest.components(separatedBy: "-")
            .filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }  // sans la date
        guard let family = parts.first, !family.isEmpty else { return id }
        let version: String = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        let name: String = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name + suffix : "\(name) \(version)\(suffix)"
    }
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
enum Panel: Equatable { case greeting, overview, empty, approval, finished, error, upload, choose, converting, result, shelf, music, dev, care, todos, friends }

private let PALETTE = ["#FF6B5B", "#2DD4A7", "#F7B32B", "#A78BFA", "#38BDF8", "#F472B6"]

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var mode: Mode = .hidden
    @Published var view: Panel = .empty
    @Published var sessions: [Session] = []
    @Published var focus: String?
    @Published var permissions: [Permission] = [] {
        didSet { if permissions.isEmpty != oldValue.isEmpty { HotKey.approvalKeys(!permissions.isEmpty) } }
    }
    @Published var files: [URL] = []
    @Published var progress = 0.0
    @Published var progressLabel = ""
    @Published var result = ""
    @Published var resultOK = true
    @Published var dropTargeted = false
    @Published var dropKeep = false

    /// Texte tapé dans la section de gauche, pour la session choisie.
    @Published var draft = ""
    @Published var composing = false  // le champ a le clavier
    @Published var sending = false
    @Published var notice: (text: String, ok: Bool)?
    /// Rend le clavier à l'app de devant (fourni par AppDelegate, qui tient le panneau).
    var releaseKeyboard: () -> Void = {}

    /// Étagère : fichiers gardés dans l'encoche le temps de les déposer ou coller ailleurs.
    @Published var shelf: [URL] = (UserDefaults.standard.stringArray(forKey: "shelf") ?? [])
        .filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    /// Un fichier de l'étagère est en train d'être glissé dehors (ce n'est pas un dépôt).
    var draggingOut = false

    let mochi = Mochi(now: CACurrentMediaTime())
    private(set) var minis: [String: Mochi] = [:]
    var notch = CGSize(width: 184, height: 32)
    var pointer = CGPoint(x: -999, y: -999)  // dans le repère du panneau (y vers le bas)

    private var hovering = false
    private var fileDragging = false
    private var droppedAt = Date.distantPast
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
        case .overview: 226
        case .empty: 150
        case .approval: 206
        case .finished: focused?.turn == nil ? 176 : (focused?.turn?.files.isEmpty ?? true) ? 196 : 226
        case .error, .choose: 176
        case .dev: devShowsServers ? 206 : 246
        case .care: 164
        case .todos: 216
        case .friends: friendsShowsChat ? 240 : 190
        case .upload, .shelf, .music: 176
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
            case .upload: return (62, mid, 38)
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
            // Un clic dans un champ, puis on s'en va sans rien taper : on n'écrivait pas vraiment.
            if composing && !typedSomething {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !self.hovering && self.composing && !self.typedSomething { self.close() }
                }
            }
        }
    }

    /// Du texte en cours dans un des champs (Claude, mini-terminal, chat).
    private var typedSomething: Bool {
        [draft, Shell.shared.command, Friends.shared.draft].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var pinned: Bool {
        // (Un menu ouvert depuis plus de 2 min : sa fermeture s'est perdue, il ne retient plus l'encoche.)
        let menu = menuOpen && Date().timeIntervalSince(menuOpenedAt ?? .distantPast) < 120
        if composing || sending || menu || Voice.shared.listening { return true }
        if !permissions.isEmpty && mode == .expanded && view == .approval { return true }
        if view == .choose || view == .converting || fileDragging { return true }
        if let pinUntil, Date() < pinUntil { return true }
        return false
    }

    private var menuOpenedAt: Date?
    private var leftAt: Date?

    /// Appelé à chaque passage du suivi de souris : l'encoche ouverte, souris dehors depuis un moment et plus
    /// rien qui la retient (message, menu, écriture…) → elle se ferme. Avant, on ne vérifiait qu'une fois,
    /// juste après la sortie de la souris : si quelque chose la retenait à cet instant, elle restait ouverte.
    func watchdog() {
        guard mode == .expanded, !hovering else { leftAt = nil; return }
        let since = leftAt ?? Date()
        leftAt = since
        if Date().timeIntervalSince(since) > 0.35 && !pinned { collapse() }
    }

    /// La croix : fermer tout de suite, même si quelque chose la retenait (une demande d'autorisation
    /// reste en attente : ⌥⇧Y / ⌥⇧N ou un survol la retrouvent).
    func close() {
        let hadKeyboard = composing
        composing = false
        Voice.shared.stop()
        pinUntil = nil
        collapse()
        if hadKeyboard {  // le clavier est rendu une fois l'encoche fermée (sinon elle clignote)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if !self.composing { self.releaseKeyboard() } }
        }
    }

    private var defaultView: Panel {
        if !sessions.isEmpty { return .overview }
        if Spotify.shared.track != nil { return .music }
        return shelf.isEmpty ? .empty : .shelf
    }

    /// Onglets du bandeau : Claude, Musique, Étagère, Dev.
    func goTo(_ p: Panel) {
        guard view != p else { return }
        Sound.shared.play("tick")
        if p == .music { Spotify.shared.refresh() }
        withAnimation(Self.openAnimation) { view = p }
    }

    /// Onglet Claude : la demande d'autorisation en attente d'abord, sinon les sessions.
    func goToClaude() {
        goTo(!permissions.isEmpty ? .approval : sessions.isEmpty ? .empty : .overview)
    }

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
        wantsFocus = false
        if composing { setComposing(false) }
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
        if draggingOut { return }  // on sort un fichier de l'étagère : ce n'est pas un dépôt
        if near && !fileDragging {
            fileDragging = true
            show(.upload, sound: "hover")
            mochi.setMouth(0.42)
        } else if !near && fileDragging {
            fileDragging = false
            // Laisse le temps au dépôt d'arriver (le bouton est relâché juste avant).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard self.view == .upload, !self.fileDragging, Date().timeIntervalSince(self.droppedAt) > 1 else { return }
                self.mochi.setMouth(0)
                if !self.hovering { self.collapse() } else { self.show(self.defaultView, sound: nil) }
            }
        }
    }

    func dropped(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        fileDragging = false
        droppedAt = Date()
        files = urls
        mochi.emote(.gulp, 0.6)
        mochi.setMouth(0)
        Sound.shared.play("gulp")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.show(.choose, sound: nil) }
    }

    // MARK: Étagère

    /// Dépôt sur « Garder ici » : les fichiers restent dans l'encoche (même après redémarrage).
    func keep(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        fileDragging = false
        droppedAt = Date()
        for u in urls where !shelf.contains(u) { shelf.append(u) }
        saveShelf()
        mochi.emote(.gulp, 0.6)
        mochi.setMouth(0)
        Sound.shared.play("gulp")
        pinUntil = Date().addingTimeInterval(2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.show(.shelf, sound: nil) }
    }

    func unshelve(_ u: URL) {
        withAnimation(.easeOut(duration: 0.2)) { shelf.removeAll { $0 == u } }
        saveShelf()
        Sound.shared.play("blip")
        if shelf.isEmpty && view == .shelf { show(defaultView, sound: nil) }
    }

    func clearShelf() {
        shelf = []
        saveShelf()
        Sound.shared.play("close")
        show(defaultView, sound: nil)
    }

    /// Clic sur un fichier : copié, prêt à être collé (⌘V) dans le Finder, un mail, un message…
    func copyFile(_ u: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([u as NSURL])
        Sound.shared.play("pop")
        mochi.emote(.happy, 0.8)
        say("\(u.lastPathComponent) copié : colle-le où tu veux (⌘V)", ok: true)
    }

    func startDragOut() {
        draggingOut = true
        Sound.shared.play("peek")
    }

    /// Appelé par le suivi de souris quand le bouton est relâché.
    func mouseReleased() {
        guard draggingOut else { return }
        draggingOut = false
        shelf = shelf.filter { FileManager.default.fileExists(atPath: $0.path) }  // déplacé ailleurs ?
        saveShelf()
    }

    private func saveShelf() {
        UserDefaults.standard.set(shelf.map(\.path), forKey: "shelf")
    }

    // MARK: Écrire à Claude (section de gauche)

    func select(_ s: Session) {
        guard focus != s.id else { return }
        focus = s.id
        Sound.shared.play("tick")
    }

    /// Le champ prend ou rend le clavier.
    func setComposing(_ on: Bool) {
        guard on != composing else { return }
        composing = on
        if on {
            lastActivity = Date()
            mochi.blink()
        } else if !hovering && !pinned {
            // On referme d'abord, et on rend le clavier une fois l'encoche fermée : rendre le clavier
            // la retire un instant de l'écran, ce qui se verrait sur l'encoche ouverte.
            collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !self.composing { self.releaseKeyboard() }
            }
        } else {
            releaseKeyboard()
        }
    }

    /// Le clavier est parti ailleurs (clic dans une autre app) : on arrête d'écrire, le brouillon reste.
    func keyboardLost() {
        guard composing else { return }
        composing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !self.hovering && !self.pinned { self.collapse() }
        }
    }

    /// Entrée : le message part dans la session choisie (voir Courier).
    func submitDraft() {
        Voice.shared.stop()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let s = focused else { return }
        deliver(text, to: s) { copied in
            self.draft = ""
            if !copied { self.say("Envoyé à Claude ✓", ok: true) }
        }
    }

    /// Change le modèle de la session choisie : `/model …` lui est envoyé comme un message.
    /// Modèle des nouvelles sessions (« model » de ~/.claude/settings.json ; vide = celui de Claude Code).
    @Published var defaultModel = ""

    func loadDefaultModel() {
        DispatchQueue.global().async {
            let m = Bridge.runHookTool("--get-model").output
            DispatchQueue.main.async { MainActor.assumeIsolated { Store.shared.defaultModel = m } }
        }
    }

    /// Les nouvelles sessions (terminal et VS Code) utiliseront ce modèle.
    func setDefaultModel(_ m: ClaudeModel) {
        DispatchQueue.global().async {
            let r = Bridge.runHookTool("--model", m.arg)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = Store.shared
                    if r.ok { store.defaultModel = m.arg }
                    Sound.shared.play(r.ok ? "approve" : "error")
                    store.say(r.ok ? "Nouvelles sessions : \(m.name) ✓" : "Réglage impossible : \(r.output)", ok: r.ok, for: 4)
                }
            }
        }
    }

    /// Session du terminal : `/model …` lui est envoyé. (L'extension VS Code n'accepte pas `/model nom` :
    /// son choix de modèle est une action de son interface. Voir ModelMenu.)
    func setModel(_ m: ClaudeModel) {
        guard let s = focused, s.model != m.arg else { return }
        deliver("/model \(m.arg)", to: s) { copied in
            guard !copied else { return }
            if var cur = self.session(s.id) { cur.model = m.arg; self.store(cur) }
            self.say("\(s.name) passe à \(m.name) ✓", ok: true)
        }
    }

    // MARK: Raccourci, favoris, capture, dictée

    /// Le champ d'écriture doit prendre le clavier dès qu'il est affiché (raccourci, capture).
    @Published var wantsFocus = false
    private var lastSummon = Date.distantPast

    /// ⌥Espace : l'encoche s'ouvre prête à écrire à la session choisie (⌥⇧Espace : en dictant).
    /// Un deuxième appui la referme.
    func summon(dictate: Bool) {
        guard Date().timeIntervalSince(lastSummon) > 0.4 else { return }  // appuis trop rapprochés
        lastSummon = Date()
        if mode == .expanded && (composing || Voice.shared.listening) {
            Voice.shared.stop()
            if composing { setComposing(false) } else { collapse() }
            return
        }
        lastActivity = Date()
        guard !sessions.isEmpty else {
            show(defaultView)
            pinUntil = Date().addingTimeInterval(3)  // ouverte au clavier : la souris n'y est pas
            return
        }
        show(.overview)
        pinUntil = Date().addingTimeInterval(1.5)  // le temps que le champ prenne le clavier
        wantsFocus = true
        if dictate { toggleDictation() }
    }

    /// Prompts favoris : un clic les envoie à la session choisie.
    @Published var favorites: [String] = UserDefaults.standard.stringArray(forKey: "favorites")
        ?? ["Continue", "Corrige les erreurs", "Lance les tests", "Fais le commit"] {
        didSet { UserDefaults.standard.set(favorites, forKey: "favorites") }
    }

    func sendFavorite(_ text: String) {
        guard let s = focused else { return }
        deliver(text, to: s) { copied in
            if !copied { self.say("« \(text) » envoyé ✓", ok: true) }
        }
    }

    /// « + » : le message en cours d'écriture devient un favori.
    func addFavorite() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return say("Écris un message, puis + pour le garder en favori.", ok: true) }
        if !favorites.contains(text) { favorites.append(text) }
        UserDefaults.standard.set(favorites, forKey: "favorites")
        Sound.shared.play("pop")
        say("Ajouté aux favoris ✓", ok: true)
    }

    func removeFavorite(_ text: String) {
        favorites.removeAll { $0 == text }
        UserDefaults.standard.set(favorites, forKey: "favorites")
        Sound.shared.play("blip")
    }

    /// Capture d'une zone de l'écran : gardée dans l'étagère, et son chemin ajouté au message
    /// pour que Claude la regarde.
    func capture() {
        let dir = Bridge.folder.appendingPathComponent("Captures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("capture-\(f.string(from: Date())).png")
        Voice.shared.stop()
        if composing { setComposing(false) }
        collapse()  // l'encoche s'efface pendant qu'on sélectionne
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", url.path]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async { MainActor.assumeIsolated { Store.shared.captured(url) } }
        }
    }

    private func captured(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }  // Échap : annulée
        if !shelf.contains(url) { shelf.append(url) }
        saveShelf()
        Sound.shared.play("pop")
        mochi.emote(.happy, 0.8)
        guard focused != nil else {
            show(.shelf, sound: nil)
            return say("Capture gardée dans l'étagère ✓", ok: true)
        }
        let tag = "Capture : \"\(url.path)\""
        let base = draft.trimmingCharacters(in: .whitespaces)
        draft = base.isEmpty ? tag + " " : base + " " + tag + " "
        show(.overview, sound: nil)
        pinUntil = Date().addingTimeInterval(1.5)
        wantsFocus = true
    }

    /// Dictée : ce qui est dit s'ajoute au message en cours.
    func toggleDictation() {
        if Voice.shared.listening { return Voice.shared.stop() }
        let base = draft.trimmingCharacters(in: .whitespaces)
        mochi.emote(.surprised, 0.6)
        Sound.shared.play("peek")
        Voice.shared.start(text: { words in
            self.draft = base.isEmpty ? words : base + " " + words
        }, failed: { why in
            Sound.shared.play("error")
            self.say(why, ok: false, for: 5)
        })
    }

    // MARK: Rappels du bonhomme

    @Published var reminder: Reminder?

    /// Un rappel (pause, eau, nuit, batterie, chaleur). Refusé (false) si on est occupé :
    /// il reviendra au prochain passage.
    func remind(_ r: Reminder) -> Bool {
        guard !busy else { return false }
        reminder = r
        switch r {
        case .pause, .night: mochi.emote(.yawn, 2.4)
        case .water: mochi.emote(.happy, 1.5)
        case .battery: mochi.emote(.surprised, 1.2)
        case .heat: mochi.emote(.worried, 2.5)
        }
        show(.care, sound: nil)
        Sound.shared.play("question")
        pinUntil = Date().addingTimeInterval(9)
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.2) {
            if self.view == .care && !self.hovering { self.collapse() }
        }
        return true
    }

    /// Réponse au rappel : « Plus tard » le fait revenir dans 10 minutes.
    func answerReminder(later: Bool) {
        if later { Care.shared.snooze() } else { mochi.emote(.happy, 0.9) }
        Sound.shared.play(later ? "blip" : "approve")
        collapse()
    }

    /// Étagère : fichiers gardés, ou historique du presse-papiers.
    @Published var shelfShowsClips = false

    /// Un menu de l'encoche est ouvert : elle reste ouverte même si la souris en sort.
    @Published var menuOpen = false

    func menuTracking(_ on: Bool) {
        menuOpen = on
        menuOpenedAt = on ? Date() : nil
        if !on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !self.hovering && !self.pinned { self.collapse() }
            }
        }
    }

    /// Envoie un texte à une session et gère les issues communes ; `done` reçoit `copied` = true
    /// quand le texte a seulement été copié (session dans un terminal).
    private func deliver(_ text: String, to s: Session, done: @escaping @MainActor (_ copied: Bool) -> Void) {
        guard !sending else { return }
        if permissions.contains(where: { $0.session == s.id }) {
            return say("Réponds d'abord à sa demande d'autorisation.", ok: false)
        }
        sending = true
        composing = false  // VS Code va prendre le clavier
        notice = ("Envoi à \(s.name)…", true)
        Courier.send(text, to: s) { outcome in
            self.sending = false
            switch outcome {
            case .sent:
                self.mochi.emote(.happy, 0.9)
                Sound.shared.play("approve")
                done(false)
            case .copied:
                Sound.shared.play("pop")
                self.say("Copié ✓ Colle-le dans la session : ⌘V puis Entrée", ok: true)
                done(true)
            case .needsPermission:
                self.releaseKeyboard()
                Sound.shared.play("question")
                self.say("Autorise Encoche dans Réglages Système → Accessibilité, puis renvoie.", ok: false, for: 6)
            case .failed(let why):
                self.releaseKeyboard()
                Sound.shared.play("error")
                self.mochi.emote(.annoyed, 0.8)
                self.say(why, ok: false, for: 5)
            }
        }
    }

    /// Petit message dans la carte de gauche (ou de l'étagère), quelques secondes.
    func say(_ text: String, ok: Bool, for seconds: Double = 3) {
        notice = (text, ok)
        pinUntil = Date().addingTimeInterval(seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.2) {
            if self.notice?.text == text { self.notice = nil }
            if !self.hovering && !self.pinned { self.collapse() }
        }
    }

    // MARK: Événements Claude Code

    func handle(_ ev: [String: Any], _ responder: Responder?) {
        let event = ev["hook_event_name"] as? String ?? ""
        if event == "EncocheDebug" { return responder?.reply(debugState) ?? () }
        let sid = ev["session_id"] as? String ?? "inconnue"
        let cwd = ev["cwd"] as? String ?? NSHomeDirectory()
        lastActivity = Date()

        if event == "SessionStart" { ended.remove(sid) }
        guard !ended.contains(sid) else { responder?.close(); return }
        if event == "SessionEnd" {
            ended.insert(sid)
            sessions.removeAll { $0.id == sid }
            saveSessions()
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
        if let entry = ev["entrypoint"] as? String, !entry.isEmpty { s.entrypoint = entry }
        if let tty = ev["tty"] as? String, !tty.isEmpty { s.tty = tty }
        if let model = ev["model"] as? String, !model.isEmpty { s.model = model }

        switch event {
        case "SessionStart":
            s.state = .idle
            s.line = "Session ouverte"
        case "UserPromptSubmit":
            s.state = .working
            s.turnStart = Date()
            if let path = ev["transcript_path"] as? String {
                s.transcript = path
                s.transcriptOffset = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
            }
            s.touched = []
            s.turn = nil
            if let p = s.plan, p.done == p.total { s.todos = [] }  // plan fini : la nouvelle demande repart à zéro
            s.line = "« \(short(ev["prompt"] as? String ?? "", 70)) »"
            push(&s)
        case "PreToolUse":
            if s.state != .approval { s.state = .working }
            if ev["tool_name"] as? String == "TodoWrite", let list = (ev["tool_input"] as? [String: Any])?["todos"] as? [[String: Any]] {
                s.todos = list.map { Todo(content: $0["content"] as? String ?? "", status: $0["status"] as? String ?? "pending",
                                          activeForm: $0["activeForm"] as? String ?? "") }
            }
            s.line = describe(ev["tool_name"] as? String ?? "", ev["tool_input"] as? [String: Any] ?? [:])
            push(&s)
        case "PostToolUse", "PostToolUseFailure":
            // Permission tranchée ailleurs (dans le terminal) : on la retire.
            for p in permissions where p.session == sid { p.responder.close() }
            permissions.removeAll { $0.session == sid }
            s.state = .working
            if event == "PostToolUseFailure" { s.line = "✗ " + s.line }
            let input = ev["tool_input"] as? [String: Any] ?? [:]
            if event == "PostToolUse", ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(ev["tool_name"] as? String ?? ""),
               let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String), !s.touched.contains(path) {
                s.touched.append(path)
            }
            if view == .approval && permissions.isEmpty && mode == .expanded { collapseSoon() }
        case "PermissionRequest":
            guard let responder else { break }
            let (title, detail) = permissionText(ev["tool_name"] as? String ?? "", ev["tool_input"] as? [String: Any] ?? [:])
            permissions.append(Permission(session: sid, title: title, detail: detail, responder: responder))
            s.state = .approval
            if draft.isEmpty && !sending { focus = sid }  // pas de changement de destinataire en pleine écriture
            store(s)
            alert(.approval, state: .approval)
            Phone.notify("Claude attend ton autorisation", "\(s.name) : \(title)", tag: "raising_hand")
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
                Phone.notify("Claude attend ta réponse", s.name, tag: "speech_balloon")
            }
        case "Stop":
            s.state = .finished
            s.line = "Terminé"
            if let start = s.turnStart {
                let turn = Turn(files: s.touched, seconds: Date().timeIntervalSince(start))
                s.turn = turn
                s.turnStart = nil
                s.line = "Terminé : " + turn.text
                if !turn.files.isEmpty { countLines(sid, cwd: s.cwd, files: turn.files) }
                if !s.transcript.isEmpty { countTokens(sid, path: s.transcript, from: s.transcriptOffset) }
                Phone.notify("Claude a terminé", "\(s.name) : \(turn.text)", tag: "white_check_mark")
            }
            if draft.isEmpty && !sending { focus = sid }  // pas de changement de destinataire en pleine écriture
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
            if draft.isEmpty && !sending { focus = sid }  // pas de changement de destinataire en pleine écriture
            store(s)
            alert(.error, state: .error)
            pinUntil = Date().addingTimeInterval(8)
            Phone.notify("Claude s'est arrêté", s.name, tag: "warning")
            return
        default:
            break
        }
        store(s)
        refreshMochi()
        if mode == .hidden && !sessions.isEmpty { withAnimation(Self.openAnimation) { mode = .compact } }
    }

    /// Tokens de la demande, lus dans l'historique de la session (une ligne JSON par message). Un même
    /// message de Claude peut tenir sur plusieurs lignes avec le même usage : on le compte une fois.
    private func countTokens(_ sid: String, path: String, from offset: UInt64) {
        DispatchQueue.global().async {
            // L'historique est écrit un peu après l'événement : on laisse le temps à la dernière réponse d'arriver.
            Thread.sleep(forTimeInterval: 0.8)
            guard let h = FileHandle(forReadingAtPath: path) else { return }
            defer { try? h.close() }
            try? h.seek(toOffset: offset)
            guard let data = try? h.readToEnd() else { return }
            var usage: [String: [String: Any]] = [:], last: [String: Any]?
            for line in data.split(separator: 0x0A) {
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], o["type"] as? String == "assistant",
                      let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
                usage[m["id"] as? String ?? UUID().uuidString] = u
                last = u
            }
            guard !usage.isEmpty else { return }
            func n(_ u: [String: Any]?, _ k: String) -> Int { (u?[k] as? Int) ?? 0 }
            let output = usage.values.reduce(0) { $0 + n($1, "output_tokens") }
            let context = n(last, "input_tokens") + n(last, "cache_read_input_tokens") + n(last, "cache_creation_input_tokens")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = Store.shared
                    guard var s = store.session(sid), s.turn != nil else { return }
                    s.turn?.output = output
                    s.turn?.context = context
                    store.store(s)
                }
            }
        }
    }

    /// Captures de plus de 7 jours qui ne sont plus dans l'étagère : supprimées (au lancement).
    func cleanCaptures() {
        let dir = Bridge.folder.appendingPathComponent("Captures"), kept = Set(shelf.map(\.path))
        let week = Date().addingTimeInterval(-7 * 24 * 3600)
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                if date < week && !kept.contains(url.path) { try? fm.removeItem(at: url) }
            }
        }
    }

    /// Lignes ajoutées / retirées (git, depuis le dernier commit) dans les fichiers de la demande.
    private func countLines(_ sid: String, cwd: String, files: [String]) {
        DispatchQueue.global().async {
            func git(_ args: [String]) -> String? {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-C", cwd] + args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return nil }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
            }
            guard let stat = git(["diff", "--numstat", "HEAD", "--"] + files) else { return }
            var added = 0, removed = 0
            for line in stat.split(separator: "\n") {
                let cols = line.split(separator: "\t")
                if cols.count >= 2 { added += Int(cols[0]) ?? 0; removed += Int(cols[1]) ?? 0 }
            }
            // Fichiers nouveaux (pas encore suivis par git) : toutes leurs lignes sont ajoutées.
            for rel in (git(["ls-files", "--others", "--exclude-standard", "--"] + files) ?? "").split(separator: "\n") {
                let url = URL(fileURLWithPath: cwd).appendingPathComponent(String(rel))
                if let text = try? String(contentsOf: url, encoding: .utf8) { added += text.split(separator: "\n", omittingEmptySubsequences: false).count }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = Store.shared
                    guard var s = store.session(sid), s.turn != nil else { return }
                    s.turn?.added = added
                    s.turn?.removed = removed
                    store.store(s)
                }
            }
        }
    }

    /// Ce que l'app voit, pour le diagnostic (événement « EncocheDebug » sur le socket).
    private var debugState: [String: Any] {
        ["mode": "\(mode)", "view": "\(view)", "hooked": hooked, "permissions": permissions.count, "ended": Array(ended),
         "sessions": sessions.map { ["id": $0.id, "name": $0.name, "state": $0.state.rawValue, "entrypoint": $0.entrypoint,
                                    "line": $0.line, "updated": $0.updated.timeIntervalSince1970] }]
    }

    private func newSession(_ id: String, _ cwd: String) -> Session {
        let color = PALETTE[sessions.count % PALETTE.count]
        let m = Mochi(mini: true, bodyColor: color, now: CACurrentMediaTime())
        minis[id] = m
        if focus == nil { focus = id }
        return Session(id: id, cwd: cwd, name: URL(fileURLWithPath: cwd).lastPathComponent, color: color)
    }

    private func store(_ s: Session) {
        let isNew = !sessions.contains { $0.id == s.id }
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        minis[s.id]?.setState(s.state)
        if isNew || Date().timeIntervalSince(savedAt) > 30 { saveSessions() }
    }

    // MARK: Sessions gardées d'un lancement à l'autre

    private var savedAt = Date.distantPast

    /// Les sessions ouvertes sont notées : après un redémarrage (mise à jour…), l'encoche les retrouve
    /// sans attendre que Claude fasse quelque chose.
    private func saveSessions() {
        savedAt = Date()
        UserDefaults.standard.set(sessions.map {
            ["id": $0.id, "cwd": $0.cwd, "name": $0.name, "color": $0.color, "term": $0.termProgram,
             "entrypoint": $0.entrypoint, "tty": $0.tty, "model": $0.model, "transcript": $0.transcript, "updated": $0.updated.timeIntervalSince1970]
        }, forKey: "sessions")
    }

    /// Au lancement : les sessions encore vivantes (historique modifié il y a moins de 12 h), au repos.
    func restoreSessions() {
        let fm = FileManager.default, limit = Date().addingTimeInterval(-12 * 3600)
        for d in UserDefaults.standard.array(forKey: "sessions") as? [[String: Any]] ?? [] {
            guard let id = d["id"] as? String, let cwd = d["cwd"] as? String, !sessions.contains(where: { $0.id == id }) else { continue }
            let transcript = d["transcript"] as? String ?? ""
            let touched = (try? fm.attributesOfItem(atPath: transcript)[.modificationDate] as? Date)
                ?? Date(timeIntervalSince1970: d["updated"] as? Double ?? 0)
            guard touched > limit else { continue }
            let color = d["color"] as? String ?? PALETTE[sessions.count % PALETTE.count]
            var s = Session(id: id, cwd: cwd, name: d["name"] as? String ?? URL(fileURLWithPath: cwd).lastPathComponent, color: color)
            s.termProgram = d["term"] as? String ?? ""
            s.entrypoint = d["entrypoint"] as? String ?? ""
            s.tty = d["tty"] as? String ?? ""
            s.model = d["model"] as? String ?? ""
            s.transcript = transcript
            s.updated = touched
            minis[id] = Mochi(mini: true, bodyColor: color, now: CACurrentMediaTime())
            sessions.append(s)
        }
        saveSessions()
        guard !sessions.isEmpty else { return }
        if focus == nil { focus = sessions.first?.id }
        refreshMochi()
        mode = .compact
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
    /// ⌥⇧Y / ⌥⇧N : on ne répond qu'à une demande affichée ; sinon le premier appui la montre.
    func answerFromKeyboard(_ decision: String) {
        guard !permissions.isEmpty else { return }
        guard mode == .expanded && view == .approval else { return show(.approval) }
        answer(decision)
    }

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
        Friends.shared.share(st, sessions: sessions.count)
    }

    /// Le plan en cours le plus récent (pour l'encoche fermée) : une session qui travaille, tâches pas finies.
    var activePlan: (done: Int, total: Int)? {
        sessions.filter { $0.state == .working || $0.state == .approval || $0.state == .waiting }
            .sorted { $0.updated > $1.updated }
            .compactMap(\.plan).first { $0.done < $0.total }
    }

    /// Couleur du bonhomme (nil : celle du skin). Les potes la voient.
    func setColor(_ hex: String?) {
        UserDefaults.standard.set(hex ?? "", forKey: "skin.color")
        mochi.tint = hex
        mochi.emote(.happy, 1)
        Sound.shared.play("pop")
        Friends.shared.skinChanged()
        objectWillChange.send()
    }

    /// Onglet Potes : les bonshommes, ou le chat.
    @Published var friendsShowsChat = false

    var chatVisible: Bool { mode == .expanded && view == .friends && friendsShowsChat }

    /// Un message d'un pote : le bonhomme réagit, et le chat s'ouvre si on n'est pas occupé.
    func chatReceived(from name: String, text: String) {
        Sound.shared.play("question")
        mochi.emote(.happy, 1.5)
        Phone.notify("Message de \(name)", text, tag: "speech_balloon")
        guard !busy else { return }
        friendsShowsChat = true
        show(.friends, sound: nil)
        pinUntil = Date().addingTimeInterval(5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
            if self.view == .friends && !self.hovering && !self.composing { self.collapse() }
        }
    }

    /// Change le skin du bonhomme (et des mini-bonshommes des sessions).
    func setSkin(_ s: Skin) {
        UserDefaults.standard.set(s.id, forKey: "skin")
        mochi.skin = s
        for m in minis.values { m.skin = s }
        mochi.emote(.happy, 1.2)
        Sound.shared.play("pop")
        Friends.shared.skinChanged()
        objectWillChange.send()
    }

    /// Onglet Dev : le mini-terminal, ou les serveurs et la santé du Mac.
    @Published var devShowsServers = false

    /// Une commande du mini-terminal est finie : si elle a duré et qu'on regardait ailleurs, le bonhomme le dit.
    func shellFinished(ok: Bool, seconds: Double) {
        guard seconds > 8, !(mode == .expanded && view == .dev) else { return }
        Sound.shared.play(ok ? "finish" : "error")
        mochi.emote(ok ? .happy : .worried, 1.8)
        guard !busy else { return }
        devShowsServers = false
        show(.dev, sound: nil)
        pinUntil = Date().addingTimeInterval(4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            if self.view == .dev && !self.hovering && !self.composing { self.collapse() }
        }
    }

    /// Un pote m'envoie un cœur ou un coucou : le bonhomme réagit, et l'onglet Potes s'ouvre si on n'est pas occupé.
    func poked(heart: Bool) {
        mochi.emote(heart ? .love : .wink, 2.2)
        Sound.shared.play(heart ? "love" : "peek")
        guard !busy else { return }
        show(.friends, sound: nil)
        pinUntil = Date().addingTimeInterval(4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            if self.view == .friends && !self.hovering { self.collapse() }
        }
    }

    /// On écrit, on autorise, on dépose un fichier… : pas le moment d'ouvrir autre chose.
    private var busy: Bool {
        let busyView: [Panel] = [.approval, .choose, .converting, .upload]
        return !permissions.isEmpty || composing || sending || fileDragging || Voice.shared.listening
            || (mode == .expanded && (hovering || busyView.contains(view)))
    }

    var focused: Session? { sessions.first { $0.id == focus } ?? sessions.first }
    var currentPermission: Permission? { permissions.first }
    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    // MARK: Aller à la session (VS Code, Terminal…)

    func jump(to s: Session) {
        openSession(s)
        Sound.shared.play("blip")
        collapse()
    }

    /// Fait passer la session devant : VS Code (la fenêtre du dossier, puis l'onglet exact de la
    /// session pour l'extension Claude Code), Terminal ou iTerm.
    func openSession(_ s: Session) {
        let ws = NSWorkspace.shared
        if s.termProgram == "Apple_Terminal" && !s.tty.isEmpty {  // le bon onglet, pas seulement l'app
            let tty = s.tty
            DispatchQueue.global().async {
                if Courier.focusTerminalTab(tty) != "ok", let app = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            return
        }
        let bundle: String
        switch s.termProgram {
        case _ where s.entrypoint == "claude-vscode": bundle = "com.microsoft.VSCode"
        case "Apple_Terminal": bundle = "com.apple.Terminal"
        case "iTerm.app": bundle = "com.googlecode.iterm2"
        default: bundle = "com.microsoft.VSCode"
        }
        guard let app = ws.urlForApplication(withBundleIdentifier: bundle) else { return }
        let urls = bundle == "com.microsoft.VSCode" ? [URL(fileURLWithPath: s.cwd)] : []
        ws.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        // Une fois la bonne fenêtre devant (le lien va à la fenêtre active), on montre l'onglet.
        guard let link = Courier.sessionLink(s) else { return }
        func reveal(_ tries: Int) {
            if ws.frontmostApplication?.bundleIdentifier == bundle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { ws.open(link) }
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reveal(tries - 1) }
            }
        }
        reveal(30)
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
        loadDefaultModel()
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
