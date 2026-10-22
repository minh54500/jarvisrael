import AppKit
import ServiceManagement
import SwiftUI

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
    /// Encoche visible ou non dans les partages d'écran, enregistrements et captures (fourni par AppDelegate).
    var applyPrivacy: (Bool) -> Void = { _ in }
    var hiddenInShares: Bool { UserDefaults.standard.object(forKey: "privacy.hide") as? Bool ?? true }

    /// Étagère : fichiers gardés dans l'encoche le temps de les déposer ou coller ailleurs.
    @Published var shelf: [URL] = (UserDefaults.standard.stringArray(forKey: "shelf") ?? [])
        .filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    /// Un fichier de l'étagère est en train d'être glissé dehors (ce n'est pas un dépôt).
    var draggingOut = false

    let mochi = Mochi(now: CACurrentMediaTime())
    var minis: [String: Mochi] = [:]
    var notch = CGSize(width: 184, height: 32)
    var pointer = CGPoint(x: -999, y: -999)  // dans le repère du panneau (y vers le bas)

    var hovering = false
    var fileDragging = false
    var droppedAt = Date.distantPast
    var pinUntil: Date?
    var lastGreet = Date.distantPast
    var lastActivity = Date()
    var slaps: [Date] = []
    var dizzyUntil: Date?
    var mochiHoverSince: Date?
    var ended = Set<String>()  // sessions fermées : on ignore leurs derniers événements
    var watchingBackground = Set<String>()  // sessions dont on surveille les agents en arrière-plan
    var resultFolder: URL?
    var createdFiles: [URL] = []
    var process: Process?

    // MARK: Géométrie (repère de l'island, en points)

    /// Transparent et sans clic hors de ce qui est dessiné : la place autour de l'encoche ouverte sert aux gouttes.
    static let panelSize = CGSize(width: 920, height: 380)
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
        case .overview: 232
        case .empty: 150
        case .approval: currentPermission?.kind == .plan ? 262 : currentPermission?.kind == .question ? 232 : 206
        case .finished: focused?.turn == nil ? 176 : (focused?.turn?.files.isEmpty ?? true) ? 196 : 226
        case .error, .choose: 176
        case .dev: tool == .servers ? 206 : tool == .mirror ? 246 : 250
        case .care: 164
        case .todos: 216
        case .friends: friendsShowsChat ? 240 : 220
        case .projects, .recap: 262
        case .welcome: 228
        case .upload: 176
        case .shelf: 190
        case .music: 196
        case .converting, .result: 150
        }
        return base + max(0, notch.height - 32)
    }

    /// La couleur de la section ouverte, en fond de ses cartes et sur son onglet : Claude terre cuite,
    /// Musique vert, Étagère bleu, Outils violet, Potes rose.
    var sectionTint: Color? {
        switch view {
        case .greeting, .welcome: nil
        case .music: Color(hex: "#1DB954")
        case .shelf: Color(hex: "#3B9EFF")
        case .dev: Color(hex: "#A78BFA")
        case .friends: Color(hex: "#F472B6")
        default: Color(hex: "#F2845C")
        }
    }

    var islandTarget: CGSize {
        switch mode {
        case .hidden: notch
        case .compact: CGSize(width: notch.width + 104, height: notch.height)
        case .peek: CGSize(width: max(notch.width + 260, 440), height: notch.height + 36)
        case .expanded: CGSize(width: Self.expandedWidth, height: viewHeight)
        }
    }

    /// Place du Mochi (centre, hauteur du corps), repère de l'island.
    var mochiSlot: (x: Double, y: Double, hb: Double) {
        switch mode {
        case .hidden: return (27, notch.height / 2, 0)
        case .compact, .peek: return (27, notch.height / 2, 17)
        case .expanded:
            let h = viewHeight, mid = cardTop + (h - cardTop - 10) / 2
            switch view {
            case .greeting: return (320, cardTop + 54, 58)
            case .upload: return (62, mid, 38)
            case .converting: return (54, mid, 30)
            // Le chat des potes montre leurs caméras à la place du bonhomme.
            case .friends where friendsShowsChat && !FriendCam.Frames.shared.images.isEmpty: return (60, mid, 0)
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
                    if self.mode == .peek { self.openToast() } else { self.expandDefault() }
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
    var typedSomething: Bool {
        [draft, Shell.shared.command, Friends.shared.draft].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || Friends.shared.noteDraft.map { $0 != Friends.shared.note } ?? false
    }

    var pinned: Bool {
        // (Un menu ouvert depuis plus de 2 min : sa fermeture s'est perdue, il ne retient plus l'encoche.)
        let menu = menuOpen && Date().timeIntervalSince(menuOpenedAt ?? .distantPast) < 120
        if composing || sending || menu || Voice.shared.listening { return true }
        if view == .dev && (Prompter.shared.showing || TextAI.shared.busy != nil) { return true }  // lecture, Claude qui réfléchit
        if view == .welcome || (view == .recap && Recap.shared.busy) { return true }
        if !permissions.isEmpty && mode == .expanded && view == .approval { return true }
        if view == .choose || view == .converting || fileDragging { return true }
        if let pinUntil, Date() < pinUntil { return true }
        return false
    }

    var menuOpenedAt: Date?
    var leftAt: Date?

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

    var defaultView: Panel {
        if !sessions.isEmpty { return .overview }
        if Spotify.shared.track != nil { return .music }
        return shelf.isEmpty ? .empty : .shelf
    }

    /// Onglets du bandeau : Claude, Musique, Étagère, Dev.
    func goTo(_ p: Panel) {
        rememberTab(p)
        if p == .overview || p == .empty { claudeSeenAt = Date() }
        guard view != p else { return }
        Sound.shared.play("tick")
        if p == .music { Spotify.shared.refresh() }
        withAnimation(Self.openAnimation) { view = p }
    }

    /// Onglet Claude : la demande d'autorisation en attente d'abord, sinon les sessions.
    func goToClaude() {
        goTo(!permissions.isEmpty ? .approval : sessions.isEmpty ? .empty : .overview)
    }

    /// Le dernier onglet choisi (Claude, Musique, Étagère, Outils, Potes) : l'encoche rouvre dessus.
    var lastTab: Panel? = {
        switch UserDefaults.standard.string(forKey: "lastTab") {
        case "music": .music
        case "shelf": .shelf
        case "dev": .dev
        case "friends": .friends
        default: nil  // Claude : la vue habituelle (sessions, ou rien qui tourne)
        }
    }()

    func rememberTab(_ p: Panel) {
        let key: String
        switch p {
        case .music: key = "music"
        case .shelf: key = "shelf"
        case .dev: key = "dev"
        case .friends: key = "friends"
        case .overview, .empty, .approval: key = "claude"
        default: return  // une alerte ou un panneau de passage ne change pas l'onglet retenu
        }
        lastTab = key == "claude" ? nil : p
        UserDefaults.standard.set(key, forKey: "lastTab")
    }

    /// À l'ouverture : l'encadré Claude Code s'il y a du nouveau, sinon le dernier onglet choisi.
    var resumeView: Panel { claudeHasNews ? defaultView : lastTab ?? defaultView }

    /// Dernière fois que tu as regardé l'encadré Claude Code.
    var claudeSeenAt = Date()

    /// Du nouveau côté Claude : une session t'attend, a un souci, travaille, ou a fini depuis ton dernier regard.
    var claudeHasNews: Bool {
        sessions.contains { s in
            s.state == .waiting || s.state == .approval || s.state == .error
                || ((s.state == .working || s.state == .finished) && s.updated > claudeSeenAt)
        }
    }

    func expandDefault() {
        if !permissions.isEmpty { return show(.approval) }
        if Date().timeIntervalSince(lastGreet) > 600 {
            lastGreet = Date()
            show(.greeting, sound: "greet")
            mochi.startGreeting()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                if self.view == .greeting && self.mode == .expanded { withAnimation(Self.openAnimation) { self.view = self.resumeView } }
            }
        } else {
            show(resumeView)
        }
    }

    /// Ne pas déranger : les messages des potes arrivent sans bulle ni son (comptés en non-lus sur l'onglet Potes), leurs
    /// cœurs et coucous sont ignorés, les rappels attendent, personne ne voit ta caméra (sauf une caméra ensemble que tu
    /// as acceptée) et les potes voient « ne pas déranger ». Claude, lui, prévient toujours.
    @Published private(set) var dnd = UserDefaults.standard.bool(forKey: "dnd")

    func setDND(_ on: Bool) {
        dnd = on
        UserDefaults.standard.set(on, forKey: "dnd")
        Friends.shared.skinChanged()  // les potes le voient tout de suite
        FriendCam.shared.dndChanged()
        Sound.shared.play(on ? "close" : "blip")
    }

    /// Tu écris dans l'encoche (à Claude, dans le chat des potes, au terminal…) : rien ne doit changer de
    /// section sous tes doigts.
    var writing: Bool {
        mode == .expanded && (composing || view == .overview && !draft.isEmpty || view == .friends && !Friends.shared.draft.isEmpty)
    }

    func show(_ v: Panel, sound: String? = "open") {
        if [.overview, .empty, .finished, .error, .approval, .todos].contains(v) { claudeSeenAt = Date() }
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
        if mode == .expanded && (view == .overview || view == .empty) { claudeSeenAt = Date() }  // tu viens de le voir
        pinUntil = nil
        if tool == .mirror { tool = .terminal }  // la caméra ne se rallume jamais toute seule à la prochaine ouverture
        toast = nil
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

    // MARK: Bulles (peek)

    @Published var toast: Toast?

    /// Encoche fermée : elle s'élargit en bulle 4 s. Ouverte : la bulle flotte en bas de l'encoche.
    func showToast(_ t: Toast) {
        toast = t
        if mode != .expanded { withAnimation(Self.openAnimation) { mode = .peek } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            guard self.toast?.id == t.id else { return }
            self.hideToast()
        }
    }

    func hideToast() {
        toast = nil
        if mode == .peek { withAnimation(Self.closeAnimation) { mode = sessions.isEmpty ? .hidden : .compact } }
    }

    /// Clic (ou survol) sur la bulle : on ouvre ce dont elle parle.
    func openToast() {
        guard let t = toast else { return }
        toast = nil
        if t.opensUpdate { collapse(); return SettingsWindow.show(.update) }
        if let p = t.opens {
            if let sid = t.session, sessions.contains(where: { $0.id == sid }) { focus = sid }
            return show(p)
        }
        if t.opensChat { friendsShowsChat = true; Friends.shared.markRead() }
        show(t.opensChat ? .friends : defaultView)
    }

    // MARK: Visite guidée

    @Published var welcomeStep = 0
    static let welcomeSteps = 5

    /// Au premier lancement (ou depuis les Réglages) : cinq petites étapes dans l'encoche.
    func startWelcome() {
        welcomeStep = 0
        show(.welcome)
    }

    func nextWelcome() {
        Sound.shared.play("tick")
        if welcomeStep + 1 < Self.welcomeSteps { withAnimation(Self.openAnimation) { welcomeStep += 1 } } else { finishWelcome() }
    }

    func finishWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomed")
        mochi.emote(.proud, 1.6)
        Sound.shared.play("approve")
        collapse()
    }

    /// Onglet Potes : les bonshommes, ou le chat.
    @Published var friendsShowsChat = false

    var chatVisible: Bool { mode == .expanded && view == .friends && friendsShowsChat }

    /// Un message d'un pote : le bonhomme réagit, et le chat s'ouvre si on n'est pas occupé.
    func chatReceived(from name: String, color: String, text: String) {
        guard !dnd else { return }  // ne pas déranger : le message attend dans le chat (compté en non-lu)
        Sound.shared.play("question")
        mochi.emote(.happy, 1.5)
        Phone.notify("Message de \(name)", text, tag: "speech_balloon")
        showToast(Toast(icon: nil, color: color, title: name, text: text, opensChat: true))
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
    /// Onglet Outils : Terminal, Serveurs · Mac, Texte IA, Miroir, Prompteur.
    enum Tool: String, CaseIterable { case terminal = "Terminal", servers = "Serveurs", text = "Texte IA", mirror = "Miroir", prompter = "Prompteur" }
    @Published var tool = Tool(rawValue: UserDefaults.standard.string(forKey: "tool") ?? "").flatMap { $0 == .mirror ? nil : $0 } ?? .terminal {
        didSet { UserDefaults.standard.set(tool.rawValue, forKey: "tool") }
    }

    /// Ouvre l'onglet Outils sur cette section (raccourci ⌥⇧R, étagère…).
    func openTool(_ t: Tool) {
        tool = t
        show(.dev, sound: nil)
        pinUntil = Date().addingTimeInterval(1.5)
    }

    /// Une commande du mini-terminal est finie : si elle a duré et qu'on regardait ailleurs, le bonhomme le dit.
    func shellFinished(ok: Bool, seconds: Double) {
        guard seconds > 8, !(mode == .expanded && view == .dev) else { return }
        Sound.shared.play(ok ? "finish" : "error")
        mochi.emote(ok ? .happy : .worried, 1.8)
        guard !busy else { return }
        tool = .terminal
        show(.dev, sound: nil)
        pinUntil = Date().addingTimeInterval(4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            if self.view == .dev && !self.hovering && !self.composing { self.collapse() }
        }
    }

    /// Un pote m'envoie un cœur ou un coucou : le bonhomme réagit, et l'onglet Potes s'ouvre si on n'est pas occupé.
    /// Un pote surveillé arrive sur son Mac.
    func friendArrived(_ name: String, color: String) {
        guard !dnd else { return }
        Sound.shared.play("peek")
        showToast(Toast(icon: "bell.fill", color: color, title: name, text: "est sur son Mac", opens: .friends))
    }

    func poked(heart: Bool, from name: String) {
        guard !dnd else { return }
        mochi.emote(heart ? .love : .wink, 2.2)
        Sound.shared.play(heart ? "love" : "peek")
        showToast(Toast(icon: heart ? "heart.fill" : "hand.wave.fill", color: heart ? "#FF5C8A" : "#F7B32B",
                        title: name, text: heart ? "t'envoie un cœur" : "te fait coucou"))
    }

    /// On écrit, on autorise, on dépose un fichier… : pas le moment d'ouvrir autre chose.
    var busy: Bool {
        let busyView: [Panel] = [.approval, .choose, .converting, .upload]
        return !permissions.isEmpty || composing || sending || fileDragging || Voice.shared.listening
            || (mode == .expanded && (hovering || busyView.contains(view)))
    }

    var focused: Session? { sessions.first { $0.id == focus } ?? sessions.first }
    var currentPermission: Permission? { permissions.first }
    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    // MARK: Réglages

    @Published var hooked = false
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    func refreshHooked() {
        loadDefaultModel()
        DispatchQueue.global().async {
            var status = Bridge.runHookTool("--status").output
            // Branchée par une version précédente : on ajoute les nouveaux événements (déjà accepté).
            if status == "incomplet", Bridge.runHookTool("--install").ok { status = "branché" }
            let on = status == "branché"
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

    // Propriétés des fonctions rangées dans StoreClaude.swift et StoreActions.swift
    // (une extension ne peut pas en avoir).
    /// Modèle des nouvelles sessions (« model » de ~/.claude/settings.json ; vide = celui de Claude Code).
    @Published var defaultModel = ""

    /// Le champ d'écriture doit prendre le clavier dès qu'il est affiché (raccourci, capture).
    @Published var wantsFocus = false
    var lastSummon = Date.distantPast

    /// Prompts favoris : un clic les envoie à la session choisie.
    @Published var favorites: [String] = UserDefaults.standard.stringArray(forKey: "favorites")
        ?? ["Continue", "Corrige les erreurs", "Lance les tests", "Fais le commit"] {
        didSet { UserDefaults.standard.set(favorites, forKey: "favorites") }
    }

    @Published var reminder: Reminder?

    /// Étagère : fichiers gardés, ou historique du presse-papiers.
    @Published var shelfShowsClips = false

    /// Un menu de l'encoche est ouvert : elle reste ouverte même si la souris en sort.
    @Published var menuOpen = false

    var savedAt = Date.distantPast
}
