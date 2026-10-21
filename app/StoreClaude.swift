import AppKit
import ServiceManagement
import SwiftUI

/// Ce qui vient de Claude Code (événements des hooks), les demandes et leurs réponses, les sessions gardées
/// et l'ouverture d'une session dans VS Code ou le Terminal.
extension Store {
    // MARK: Événements Claude Code

    func handle(_ ev: [String: Any], _ responder: Responder?) {
        let event = ev["hook_event_name"] as? String ?? ""
        if event == "EncocheDebug" { return responder?.reply(debugState) ?? () }
        if event == "EncocheCamTest" { return FriendCam.shared.selfTest { responder?.reply($0) } }
        if event == "EncocheFriendTest" { return responder?.reply(Friends.shared.diagnose(ev)) ?? () }
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
        // Claude lui-même se remet au travail (pas un de ses agents) : on sort de l'arrière-plan.
        if ev["agent_id"] == nil, ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "StopFailure"].contains(event) {
            s.background = false
        }

        switch event {
        case "SessionStart":
            s.state = .idle
            s.line = "Session ouverte"
        case "UserPromptSubmit":
            // Pas un message de Minh : le rapport d'un agent en arrière-plan, ou le message d'une autre session.
            // Claude reprend la même demande : son bilan en cours et les demandes affichées restent.
            let prompt = ev["prompt"] as? String ?? ""
            if s.turnStart != nil, ["<task-notification", "<agent-message", "<cross-session-message"].contains(where: { prompt.hasPrefix($0) }) {
                s.state = .working
                s.line = prompt.hasPrefix("<task-notification") ? "Lit le rapport de l'agent…" : "Lit un message d'une autre session…"
                push(&s)
                break
            }
            // Nouveau message : les demandes de Claude encore affichées n'attendent plus rien. Celles de ses agents
            // en arrière-plan, si (elles disparaissent seules si leur agent les abandonne).
            for p in permissions where p.session == sid && p.agent == nil { p.responder.close() }
            permissions.removeAll { $0.session == sid && $0.agent == nil }
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
        case "PreToolUse" where responder != nil:
            // Une question de Claude ou son plan : la réponse viendra de l'encoche (ou de VS Code, au choix).
            let tool = ev["tool_name"] as? String ?? ""
            let input = ev["tool_input"] as? [String: Any] ?? [:]
            let plan = tool == "ExitPlanMode"
            var p = Permission(session: sid, title: plan ? "propose un plan" : "te pose une question",
                               detail: plan ? short(input["plan"] as? String ?? "", 200) : "", responder: responder!)
            p.kind = plan ? .plan : .question
            p.input = input
            p.agent = ev["agent_id"] as? String
            permissions.append(p)
            watch(p)
            s.state = plan ? .approval : .waiting
            s.line = plan ? "Propose un plan" : "Te pose une question"
            push(&s)
            if draft.isEmpty && !sending { focus = sid }
            store(s)
            alert(.approval, state: s.state, session: s)
            Phone.notify(plan ? "Claude propose un plan" : "Claude te pose une question", s.name, tag: "question")
            let id = p.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 117) { self.expire(id) }
            return
        case "SubagentStart":
            let type = ev["agent_type"] as? String ?? "agent"
            s.agents[ev["agent_id"] as? String ?? UUID().uuidString] = type
            s.state = .working
            s.line = "Lance un sous-agent : \(type)"
            push(&s)
        case "SubagentStop":
            s.agents.removeValue(forKey: ev["agent_id"] as? String ?? "")
            if s.background && s.agents.isEmpty { return backgroundDone(s) }
        case "PreCompact":
            s.line = "Fait de la place dans sa mémoire…"
            push(&s)
            mochi.emote(.yawn, 1.6)
        case "PostCompact":
            s.line = "Mémoire compressée ✓"
            push(&s)
        case "PreToolUse":
            if s.state != .approval { s.state = .working }
            if ev["tool_name"] as? String == "TodoWrite", let list = (ev["tool_input"] as? [String: Any])?["todos"] as? [[String: Any]] {
                s.todos = list.map { Todo(content: $0["content"] as? String ?? "", status: $0["status"] as? String ?? "pending",
                                          activeForm: $0["activeForm"] as? String ?? "") }
            }
            s.line = describe(ev["tool_name"] as? String ?? "", ev["tool_input"] as? [String: Any] ?? [:])
            if let id = ev["agent_id"] as? String, let type = (ev["agent_type"] as? String) ?? s.agents[id] { s.line = "\(type) · " + s.line }
            push(&s)
        case "PostToolUse", "PostToolUseFailure":
            // Permission tranchée ailleurs (dans le terminal) : on la retire. Seulement celles du même agent :
            // les outils d'un sous-agent portent l'identifiant de la session, mais pas la même demande.
            let agent = ev["agent_id"] as? String
            for p in permissions where p.session == sid && p.agent == agent { p.responder.close() }
            permissions.removeAll { $0.session == sid && $0.agent == agent }
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
            var request = Permission(session: sid, title: title, detail: detail, responder: responder)
            request.agent = ev["agent_id"] as? String
            permissions.append(request)
            watch(request)
            s.state = .approval
            if draft.isEmpty && !sending { focus = sid }  // pas de changement de destinataire en pleine écriture
            store(s)
            alert(.approval, state: .approval, session: s)
            Phone.notify("Claude attend ton autorisation", "\(s.name) : \(title)", tag: "raising_hand")
            // Claude Code abandonne le hook après 120 s : on retire la demande avant.
            let id = permissions.last!.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 117) { self.expire(id) }
            return
        case "Notification":
            let type = ev["notification_type"] as? String ?? ""
            if type != "permission_prompt" && !s.background && !permissions.contains(where: { $0.session == sid }) {
                s.state = .waiting
                s.line = ev["message"] as? String ?? "Claude attend ta réponse"
                Sound.shared.play("question")
                Phone.notify("Claude attend ta réponse", s.name, tag: "speech_balloon")
            }
        case "Stop":
            // Des agents lancés en arrière-plan bossent encore : l'encoche le montre, et le bilan attendra la vraie fin.
            s.agents = Self.backgroundAgents(ev)
            if !s.agents.isEmpty {
                s.background = true
                s.state = .working
                s.line = s.agents.count == 1 ? "« \(s.agents.values.first!) » bosse en arrière-plan…" : "\(s.agents.count) agents bossent en arrière-plan…"
                store(s)
                refreshMochi()
                return watchBackground(sid)
            }
            s.background = false
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
                alert(.finished, state: .finished, session: s)
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
            alert(.error, state: .error, session: s)
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
    func countTokens(_ sid: String, path: String, from offset: UInt64) {
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
        // Les captures, et les copies des fichiers déposés (voir DroppedFiles), qui ne sont plus sur l'étagère.
        let dirs = [Bridge.folder.appendingPathComponent("Captures"), DroppedFiles.folder], kept = Set(shelf.map(\.path))
        let week = Date().addingTimeInterval(-7 * 24 * 3600)
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for dir in dirs {
                for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                    if date < week && !kept.contains(url.path) { try? fm.removeItem(at: url) }
                }
            }
        }
    }

    /// Lignes ajoutées / retirées (git, depuis le dernier commit) dans les fichiers de la demande.
    func countLines(_ sid: String, cwd: String, files: [String]) {
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
    var debugState: [String: Any] {
        ["mode": "\(mode)", "view": "\(view)", "hooked": hooked, "permissions": permissions.count, "ended": Array(ended),
         "usage": [Usage.shared.fiveHour?.used ?? -1, Usage.shared.week?.used ?? -1],
         "sessions": sessions.map { ["id": $0.id, "name": $0.name, "state": $0.state.rawValue, "entrypoint": $0.entrypoint,
                                    "line": $0.line, "updated": $0.updated.timeIntervalSince1970] }]
    }

    func newSession(_ id: String, _ cwd: String) -> Session {
        let color = PALETTE[sessions.count % PALETTE.count]
        let m = Mochi(mini: true, bodyColor: color, now: CACurrentMediaTime())
        minis[id] = m
        if focus == nil { focus = id }
        return Session(id: id, cwd: cwd, name: URL(fileURLWithPath: cwd).lastPathComponent, color: color)
    }

    func store(_ s: Session) {
        let isNew = !sessions.contains { $0.id == s.id }
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        minis[s.id]?.setState(s.state)
        if isNew || Date().timeIntervalSince(savedAt) > 30 { saveSessions() }
    }

    // MARK: Sessions gardées d'un lancement à l'autre
    /// Les sessions ouvertes sont notées : après un redémarrage (mise à jour…), l'encoche les retrouve
    /// sans attendre que Claude fasse quelque chose.
    func saveSessions() {
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

    func push(_ s: inout Session) {
        s.history.append(s.line)
        if s.history.count > 6 { s.history.removeFirst() }
    }

    /// Les agents lancés en arrière-plan qui tournent encore (identifiant → type), d'après le champ
    /// `background_tasks` que Claude Code joint au Stop. Les tâches shell (un serveur lancé en fond…) n'en sont pas.
    nonisolated static func backgroundAgents(_ ev: [String: Any]) -> [String: String] {
        var found: [String: String] = [:]
        for t in ev["background_tasks"] as? [[String: Any]] ?? [] {
            guard let id = t["id"] as? String else { continue }
            switch t["type"] as? String {
            case "subagent": found[id] = (t["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "agent"
            case "workflow": found[id] = (t["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "workflow"
            default: break
            }
        }
        return found
    }

    /// Filet de sécurité, chaque minute tant que la session est en arrière-plan : ses agents envoient un événement
    /// à chaque outil ; plus rien depuis 20 min veut dire qu'ils se sont arrêtés sans prévenir.
    func watchBackground(_ sid: String) {
        guard !watchingBackground.contains(sid) else { return }
        watchingBackground.insert(sid)
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                guard let s = self.sessions.first(where: { $0.id == sid }), s.background else {
                    self.watchingBackground.remove(sid)
                    return
                }
                if Date().timeIntervalSince(s.updated) > 20 * 60 {
                    self.watchingBackground.remove(sid)
                    return self.backgroundDone(s)
                }
                check()
            }
        }
        check()
    }

    /// Les agents ont fini : Claude va lire leur rapport (son Stop fera le vrai bilan).
    func backgroundDone(_ session: Session) {
        var s = session
        s.background = false
        s.state = .finished
        s.line = "Agent terminé"
        store(s)
        refreshMochi()
        Sound.shared.play("pop")
        let sid = s.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.settle(sid) }
    }

    func settle(_ sid: String) {
        guard var s = sessions.first(where: { $0.id == sid }), s.state == .finished else { return }
        s.state = .idle
        store(s)
        refreshMochi()
    }

    func alert(_ v: Panel, state: BotState, session: Session? = nil) {
        refreshMochi()
        if mode == .expanded && view == .approval && v != .approval && !permissions.isEmpty { return }
        if writing {  // une bulle en haut de l'encoche, pour la session qui vient de bouger ; un clic l'ouvre
            let s = session ?? focused
            let ask = permissions.last { $0.session == s?.id }
            let text = v == .approval ? (ask.map { "\($0.title) — clic pour répondre" } ?? "attend ta réponse")
                : v == .error ? "s'est arrêté" : (s?.line ?? "Terminé")
            showToast(Toast(icon: v == .approval ? "hand.raised.fill" : v == .error ? "exclamationmark.triangle.fill" : "checkmark",
                            color: STYLES[state]?.col ?? "#9A9FA8", title: s?.name ?? "Claude", text: text, opens: v, session: s?.id))
            return Sound.shared.play(STYLES[state]?.sound ?? "blip")
        }
        show(v, sound: nil)
        Sound.shared.play(STYLES[state]?.sound ?? "blip")
    }

    func collapseSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            if !self.permissions.isEmpty { return self.show(.approval, sound: nil) }
            if self.hovering { self.show(self.defaultView, sound: nil) } else { self.collapse() }
        }
    }

    /// Si le hook s'en va sans réponse (Claude Code a abandonné), la carte disparaît de l'encoche.
    func watch(_ p: Permission) {
        let id = p.id
        p.responder.onGone = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.permissions.contains(where: { $0.id == id }) else { return }
                self.permissions.removeAll { $0.id == id }
                self.refreshMochi()
                if self.permissions.isEmpty && self.view == .approval { self.collapseSoon() }
            }
        }
        p.responder.watchClose()
    }

    func expire(_ id: UUID) {
        guard let p = permissions.first(where: { $0.id == id }) else { return }
        p.responder.close()
        permissions.removeAll { $0.id == id }
        if permissions.isEmpty && view == .approval { collapseSoon() }
    }

    /// Réponse depuis l'encoche : "allow", "always" ou "deny".
    /// ⌥⇧Y / ⌥⇧N : on ne répond qu'à une demande affichée ; sinon le premier appui la montre.
    func answerFromKeyboard(_ decision: String) {
        guard let p = permissions.first else { return }
        guard mode == .expanded && view == .approval else { return show(.approval) }
        switch p.kind {
        case .tool: answer(decision)
        case .plan: decision == "allow" ? approvePlan() : revisePlan(nil)
        case .question: break  // il faut choisir une réponse
        }
    }

    /// Réponses aux questions de Claude : { texte de la question : choix (plusieurs : séparés par des virgules) }.
    func answerQuestion(_ answers: [String: String]) {
        guard let p = permissions.first, p.kind == .question else { return }
        var input = p.input
        input["answers"] = answers
        finish(p, ["permissionDecision": "allow", "updatedInput": input], working: true)
    }

    func approvePlan() {
        guard let p = permissions.first, p.kind == .plan else { return }
        finish(p, ["permissionDecision": "allow", "updatedInput": p.input], working: true)
    }

    /// « Modifier » (avec ce qu'il faut changer) ou « Refuser » (sans) : Claude reste en mode plan.
    func revisePlan(_ feedback: String?) {
        guard let p = permissions.first, p.kind == .plan else { return }
        let f = feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        finish(p, ["permissionDecision": "deny",
                   "message": f.isEmpty ? "Plan refusé depuis l'encoche." : "Je veux des changements au plan : \(f)"], working: !f.isEmpty)
    }

    /// « Répondre dans VS Code » : l'encoche s'efface, Claude Code pose la question lui-même.
    func answerElsewhere() {
        guard let p = permissions.first else { return }
        p.responder.close()
        permissions.removeFirst()
        if let s = session(p.session) { jump(to: s) } else { collapseSoon() }
    }

    func finish(_ p: Permission, _ reply: [String: Any], working: Bool) {
        p.responder.reply(reply)
        permissions.removeAll { $0.id == p.id }
        if var s = sessions.first(where: { $0.id == p.session }) {
            s.state = working ? .working : .idle
            store(s)
        }
        Sound.shared.play("approve")
        mochi.emote(.happy, 0.9)
        refreshMochi()
        collapseSoon()
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
        case _ where s.inApp: bundle = ClaudeApp.bundle  // l'app n'a pas de lien vers une session : elle passe devant
        case "Apple_Terminal": bundle = "com.apple.Terminal"
        case "iTerm.app": bundle = "com.googlecode.iterm2"
        default: bundle = "com.microsoft.VSCode"
        }
        guard let app = bundle == ClaudeApp.bundle ? ClaudeApp.app : ws.urlForApplication(withBundleIdentifier: bundle) else { return }
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
}

// MARK: - Textes

func short(_ s: String, _ n: Int) -> String {
    let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    return one.count > n ? String(one.prefix(n - 1)) + "…" : one
}

func fileName(_ input: [String: Any]) -> String {
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

func permissionText(_ tool: String, _ input: [String: Any]) -> (String, String) {
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
