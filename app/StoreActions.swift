import AppKit
import ServiceManagement
import SwiftUI

/// Les actions : étagère, écrire à Claude, favoris, capture, dictée, rappels, conversion de fichiers.
extension Store {
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
        DroppedFiles.forget([u])
        saveShelf()
        Sound.shared.play("blip")
        if shelf.isEmpty && view == .shelf { show(defaultView, sound: nil) }
    }

    func clearShelf() {
        DroppedFiles.forget(shelf)
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

    func saveShelf() {
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

    /// Nouvelle conversation ou session (bouton « + ») : ce que tu as tapé part avec, déjà écrit.
    func openNew(_ kind: ClaudeApp.Kind, folder: String? = nil, place: OpenIn = .app) {
        Voice.shared.stop()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .code, let folder {
            guard Projects.shared.start(in: folder, prompt: text, place: place) else { return }
        } else {
            guard ClaudeApp.open(kind, prompt: text) else { return }
            collapse()
        }
        draft = ""
    }

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

    func captured(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }  // Échap : annulée
        // Annoter d'abord (flèche, cadre, stylo), sauf si c'est coupé dans les Réglages.
        guard UserDefaults.standard.object(forKey: "annotate") as? Bool ?? true else { return keepCapture(url, send: true) }
        Annotator.open(url) { result, send in
            MainActor.assumeIsolated { if let result { Store.shared.keepCapture(result, send: send) } }
        }
    }

    /// La capture (annotée ou non) : dans l'étagère, et dans le message à Claude si on l'envoie.
    func keepCapture(_ url: URL, send: Bool) {
        if !shelf.contains(url) { shelf.append(url) }
        saveShelf()
        Sound.shared.play("pop")
        mochi.emote(.happy, 0.8)
        guard send, focused != nil else {
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
    /// Un rappel (pause, eau, nuit, batterie, chaleur). Refusé (false) si on est occupé :
    /// il reviendra au prochain passage.
    func remind(_ r: Reminder) -> Bool {
        guard !busy, !dnd else { return false }  // ne pas déranger : le rappel attend la fin du mode
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
    func deliver(_ text: String, to s: Session, done: @escaping @MainActor (_ copied: Bool) -> Void) {
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
}
