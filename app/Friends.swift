import AppKit
import SwiftUI

/// Entre potes : chacun partage son bonhomme (humeur, skin, couleur) et sa présence (sur son Mac,
/// absent, hors ligne) dans un groupe — un sujet ntfy secret que vous partagez — et voit ceux des autres.
/// Il y a aussi un chat de groupe, et les cœurs / coucous. Jamais de projets ni de messages à Claude :
/// seuls le pseudo, l'état et ce que vous écrivez dans le chat passent par ntfy.
@MainActor
final class Friends: NSObject, ObservableObject, URLSessionDataDelegate {
    static let shared = Friends()
    static let server = "https://ntfy.sh"

    enum Presence: String { case active, away, off }

    final class Friend: Identifiable {
        let id: String
        var name: String
        var state: BotState
        var sessions: Int
        var seen: Date            // dernier message reçu de lui
        var presence: Presence
        var since: Date           // depuis quand il est dans cette présence
        var cam = false           // partage sa caméra (voir FriendCam)
        var dnd = false           // en mode « ne pas déranger »
        var note = ""             // son statut (« en call client »)
        var music: String?        // ce qu'il écoute sur Spotify (« Titre — Artiste »), s'il le partage
        var musicID: String?      // spotify:track:…, pour l'ouvrir chez soi
        let mochi: Mochi

        /// Hors ligne s'il l'a dit (veille, app quittée) ou sans nouvelles depuis 45 min (signe de vie toutes les 20).
        var online: Bool { presence != .off && Date().timeIntervalSince(seen) < 45 * 60 }
        var color: Color { Color(hex: mochi.tint ?? mochi.skin.aura) }

        init(id: String, name: String, state: BotState, sessions: Int, seen: Date, presence: Presence, since: Date,
             skin: String?, tint: String?) {
            self.id = id; self.name = name; self.state = state; self.sessions = sessions
            self.seen = seen; self.presence = presence; self.since = since
            mochi = Mochi(skin: Skin.named(skin ?? "galet"), tint: tint, now: CACurrentMediaTime())
            mochi.setState(state, force: true)
        }
    }

    struct Message: Identifiable, Codable, Equatable {
        let id: String
        let from: String
        let name: String
        let text: String
        let at: Date
        var mine: Bool
        /// Mes messages : « sending », « sent » ou « failed » (absent pour ceux des potes).
        var state: String?
        /// Réactions : emoji → identifiants de ceux qui l'ont mis.
        var reactions: [String: [String]]?
    }

    static let reactionEmojis = ["👍", "😂", "❤️", "😮"]

    /// Jusqu'où chaque pote a lu le chat (date du dernier message qu'il a vu) : « Vu par … ».
    @Published private(set) var seenBy: [String: Date] = [:]
    private var seenSent = Date.distantPast
    /// Les potes dont je veux savoir quand ils arrivent sur leur Mac.
    @Published private(set) var watched = Set(UserDefaults.standard.stringArray(forKey: "friends.watch") ?? [])
    private var arrived: [String: Date] = [:]
    private var connectedAt = Date()

    @Published private(set) var list: [Friend] = []
    @Published private(set) var notice: String?
    @Published private(set) var chat: [Message] = []
    @Published private(set) var unread = 0
    @Published var draft = ""

    // Réglages (fenêtre Réglages, section « Entre potes »).
    var enabled: Bool { UserDefaults.standard.bool(forKey: "friends.on") }
    var group: String { (UserDefaults.standard.string(forKey: "friends.group") ?? "").trimmingCharacters(in: .whitespaces) }
    var name: String {
        let n = (UserDefaults.standard.string(forKey: "friends.name") ?? "").trimmingCharacters(in: .whitespaces)
        return String((n.isEmpty ? "Un pote" : n).prefix(20))
    }
    var configured: Bool { enabled && !group.isEmpty }
    let me: String = {
        if let id = UserDefaults.standard.string(forKey: "friends.id") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "friends.id")
        return id
    }()

    private var stream: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var sent: (signature: String, at: Date)?
    private var pending: Timer?
    private var heartbeat: Timer?
    private var presenceTimer: Timer?
    private var current = (state: BotState.idle, sessions: 0)
    private var presence = Presence.active
    private var presenceSince = Date()
    private var lastPoke = Date.distantPast
    private var restartTimer: Timer?

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "friends.chat"),
           let saved = try? JSONDecoder().decode([Message].self, from: data) {
            // Un envoi coupé par la fermeture de l'app n'est jamais parti.
            chat = saved.map { var m = $0; if m.state == "sending" { m.state = "failed" }; return m }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Friends.shared.goOffline() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Friends.shared.restart() }
        }
    }

    static func newGroup() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "encoche-potes-" + String((0..<12).map { _ in chars.randomElement()! })
    }

    /// Réglages en cours de saisie : on attend la fin de la frappe avant de se rebrancher.
    func restartSoon() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated { Friends.shared.restart() }
        }
    }

    /// (Re)branche le groupe selon les réglages.
    func restart() {
        task?.cancel()
        task = nil
        heartbeat?.invalidate()
        presenceTimer?.invalidate()
        list = []
        sent = nil
        FriendCam.shared.closeAll()
        // Autre groupe : on repart d'un chat vide.
        if UserDefaults.standard.string(forKey: "friends.chatGroup") != group {
            UserDefaults.standard.set(group, forKey: "friends.chatGroup")
            chat = []
            unread = 0
            saveChat()
        }
        guard configured else { return }
        // La vraie présence (pas « présent » d'office) : relancer l'app pendant une pause n'est pas une arrivée.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        presence = idle < 180 ? .active : .away
        presenceSince = Date().addingTimeInterval(presence == .away ? -idle : 0)
        connect()
        publish(force: true)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Friends.shared.publish(force: true) }
        }
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            // (Le morceau en cours part avec le prochain statut : rien de forcé, ntfy gratuit limite les messages.)
            MainActor.assumeIsolated { Friends.shared.checkPresence() }
        }
    }

    // MARK: Ce que je partage

    /// Appelé quand l'humeur du bonhomme change.
    func share(_ state: BotState, sessions: Int) {
        current = (state == .finished || state == .dizzy ? .idle : state, sessions)
        changed()
    }

    /// Nouveau skin ou nouvelle couleur : les potes le voient tout de suite.
    func skinChanged() { publish(force: true) }

    /// Sur son Mac = clavier ou souris touchés dans les 3 dernières minutes.
    private func checkPresence() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let now: Presence = idle < 180 ? .active : .away
        guard now != presence else { return }
        presence = now
        presenceSince = Date().addingTimeInterval(now == .away ? -idle : 0)
        changed()
    }

    /// Veille ou app quittée : on le dit tout de suite (en attendant un peu que le message parte).
    func goOffline() {
        guard configured else { return }
        FriendCam.shared.closeAll()
        presence = .off
        presenceSince = Date()
        let done = DispatchSemaphore(value: 0)
        post(status(), then: { _ in done.signal() })
        _ = done.wait(timeout: .now() + 1.5)
        sent = (signature, Date())
    }

    private var signature: String {
        "\(current.state.rawValue)|\(presence.rawValue)|\(Skin.current.id)|\(Skin.tint ?? "")|\(name)|\(FriendCam.shared.sharing)|\(Store.shared.dnd)|\(note)"
    }

    /// Au plus un message toutes les 30 s (ntfy gratuit limite le nombre de messages par jour) :
    /// les changements rapprochés sont regroupés.
    private func changed() {
        guard configured, sent?.signature != signature, pending == nil else { return }
        let wait = 30 - Date().timeIntervalSince(sent?.at ?? .distantPast)
        if wait <= 0 { return publish(force: false) }
        pending = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated {
                Friends.shared.pending = nil
                Friends.shared.publish(force: false)
            }
        }
    }

    private func publish(force: Bool) {
        guard configured, force || sent?.signature != signature else { return }
        sent = (signature, Date())
        post(status())
    }

    private func status() -> [String: Any] {
        ["kind": "status", "state": current.state.rawValue, "sessions": current.sessions, "skin": Skin.current.id,
         "color": Skin.tint ?? "", "presence": presence.rawValue, "since": presenceSince.timeIntervalSince1970,
         "cam": FriendCam.shared.sharing, "dnd": Store.shared.dnd, "note": note]
            .merging(music.map { ["music": $0.text, "musicID": $0.id] } ?? [:]) { a, _ in a }
    }

    /// Un cœur (« heart ») ou un coucou (« wave ») au bonhomme d'un pote.
    func poke(_ f: Friend, _ emote: String) {
        guard configured, Date().timeIntervalSince(lastPoke) > 2 else { return }
        lastPoke = Date()
        post(["kind": "poke", "to": f.id, "emote": emote])
        Sound.shared.play("pop")
        say(emote == "heart" ? "Cœur envoyé à \(f.name) ✓" : "Coucou envoyé à \(f.name) ✓")
    }

    /// Les messages de la caméra entre potes (demande, description de connexion, arrêt), pour un seul pote.
    func signal(_ fields: [String: Any]) {
        guard configured else { return }
        post(fields)
    }

    // MARK: Chat

    static let chatLimit = 500

    func sendChat(_ quick: String? = nil) {
        let text = String((quick ?? draft).trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.chatLimit))
        guard configured, !text.isEmpty else { return }
        let id = UUID().uuidString
        add(Message(id: id, from: me, name: name, text: text, at: Date(), mine: true, state: "sending"))
        if quick == nil { draft = "" }
        Sound.shared.play("pop")
        deliver(id, text)
    }

    /// Réessayer un message qui n'est pas parti.
    func retry(_ m: Message) {
        guard m.mine, m.state == "failed" else { return }
        setState(m.id, "sending")
        deliver(m.id, m.text)
    }

    private func deliver(_ id: String, _ text: String) {
        post(["kind": "chat", "text": text, "mid": id]) { ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Friends.shared.setState(id, ok ? "sent" : "failed")
                    if !ok { Sound.shared.play("error") }
                }
            }
        }
    }

    private func setState(_ id: String, _ state: String) {
        guard let i = chat.firstIndex(where: { $0.id == id }) else { return }
        chat[i].state = state
        saveChat()
    }

    func markRead() {
        if unread != 0 { unread = 0 }
        sendSeen()
    }

    // MARK: Réactions, « vu »

    /// Mettre (ou retirer) une réaction sur un message.
    func react(_ msg: Message, _ emoji: String) {
        guard configured else { return }
        let on = !(msg.reactions?[emoji]?.contains(me) ?? false)
        setReaction(msg.id, emoji, by: me, on: on)
        post(["kind": "react", "mid": msg.id, "emoji": emoji, "on": on])
        Sound.shared.play("tick")
    }

    private func setReaction(_ mid: String, _ emoji: String, by who: String, on: Bool) {
        guard let i = chat.firstIndex(where: { $0.id == mid }) else { return }
        var r = chat[i].reactions ?? [:]
        var people = r[emoji] ?? []
        people.removeAll { $0 == who }
        if on { people.append(who) }
        r[emoji] = people.isEmpty ? nil : people
        chat[i].reactions = r.isEmpty ? nil : r
        saveChat()
    }

    /// Le chat est sous mes yeux : je dis jusqu'où j'ai lu, une fois la conversation calme (5 s sans nouveau
    /// message) pour ne pas user les messages gratuits de ntfy, et seulement si le dernier message n'est pas le mien.
    private func sendSeen() {
        seenWork?.cancel()
        let work = DispatchWorkItem {
            let fr = Friends.shared
            guard fr.configured, Store.shared.chatVisible, fr.chat.last?.mine == false,
                  let last = fr.chat.last(where: { !$0.mine }), last.at > fr.seenSent else { return }
            fr.seenSent = last.at
            fr.post(["kind": "seen", "at": last.at.timeIntervalSince1970])
        }
        seenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
    private var seenWork: DispatchWorkItem?

    /// Qui a vu mon dernier message.
    func seenNames(after date: Date) -> [String] {
        list.filter { (seenBy[$0.id] ?? .distantPast) >= date.addingTimeInterval(-3) }.map(\.name)
    }

    // MARK: Statut perso, musique, arrivées

    static let noteLimit = 40
    var note: String { String((UserDefaults.standard.string(forKey: "friends.note") ?? "").prefix(Self.noteLimit)) }
    /// Le statut en cours d'écriture (nil hors écriture) : gardé ici, il survit à la fermeture de l'encoche.
    @Published var noteDraft: String?

    func setNote(_ text: String) {
        var t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.noteLimit))
        while t.utf8.count > 160 { t.removeLast() }  // des emoji composés pèsent lourd : le statut reste petit
        noteDraft = nil
        UserDefaults.standard.set(t, forKey: "friends.note")
        objectWillChange.send()
        changed()
        say(t.isEmpty ? "Statut effacé" : "Statut : « \(t) »")
    }

    /// Ce que j'écoute, si je le partage (Réglages → Potes) et que Spotify joue.
    private var music: (text: String, id: String)? {
        guard UserDefaults.standard.bool(forKey: "friends.music"), Spotify.shared.playing, let t = Spotify.shared.track,
              !t.name.isEmpty else { return nil }
        return (String((t.artist.isEmpty ? t.name : "\(t.name) — \(t.artist)").prefix(80)), t.id)
    }

    nonisolated static func trackID(_ s: String?) -> String? {
        guard let s, s.range(of: "^spotify:track:[A-Za-z0-9]{22}$", options: .regularExpression) != nil else { return nil }
        return s
    }

    private func arrival(_ id: String, _ name: String, _ color: String?, _ aura: String) {
        guard watched.contains(id), Date().timeIntervalSince(connectedAt) > 90,
              Date().timeIntervalSince(arrived[id] ?? .distantPast) > 30 * 60 else { return }
        arrived[id] = Date()
        Store.shared.friendArrived(name, color: color.flatMap { $0.isEmpty ? nil : $0 } ?? aura)
    }

    func toggleWatch(_ f: Friend) {
        if watched.contains(f.id) { watched.remove(f.id) } else { watched.insert(f.id) }
        UserDefaults.standard.set(Array(watched), forKey: "friends.watch")
        say(watched.contains(f.id) ? "Je te préviens quand \(f.name) arrive sur son Mac" : "Plus d'alerte pour \(f.name)")
    }

    private func add(_ m: Message) {
        guard !chat.contains(where: { $0.id == m.id }) else { return }
        chat.append(m)
        chat.sort { $0.at < $1.at }
        if chat.count > 150 { chat.removeFirst(chat.count - 150) }
        saveChat()
    }

    private func saveChat() {
        if let data = try? JSONEncoder().encode(chat) { UserDefaults.standard.set(data, forKey: "friends.chat") }
    }

    private func post(_ fields: [String: Any], then done: ((Bool) -> Void)? = nil) {
        var payload = fields
        payload["app"] = "encoche"
        payload["v"] = 1
        payload["id"] = me
        payload["name"] = name
        guard let body = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: body, encoding: .utf8),
              let url = URL(string: Self.server) else { done?(false); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Priorité minimale : si quelqu'un s'abonne au groupe sur son téléphone, ça ne sonne pas.
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["topic": group, "message": text, "priority": 1, "tags": ["encoche"]])
        URLSession.shared.dataTask(with: req) { _, response, error in
            done?(error == nil && (response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    // MARK: Ce que je reçois (flux ntfy : une ligne JSON par message)

    private func connect() {
        connectedAt = Date()  // les statuts rejoués à la connexion ne comptent pas comme des arrivées
        guard configured, let topic = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(Self.server)/\(topic)/json?since=6h") else { return }
        if stream == nil {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 150  // ntfy envoie un signe de vie toutes les 45 s
            stream = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        }
        buffer = Data()
        task = stream?.dataTask(with: url)
        task?.resume()
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard dataTask === task else { return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                receive(line)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task done: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard done === task else { return }
            task = nil
            // Coupure (Wi-Fi, veille) : on se rebranche un peu plus tard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if Friends.shared.configured && Friends.shared.task == nil { Friends.shared.connect() }
            }
        }
    }

    private func receive(_ line: Data) {
        guard let ev = try? JSONSerialization.jsonObject(with: line) as? [String: Any], ev["event"] as? String == "message",
              let text = ev["message"] as? String, let data = text.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              m["app"] as? String == "encoche", let id = m["id"] as? String, id != me else { return }
        let at = Date(timeIntervalSince1970: ev["time"] as? Double ?? Date().timeIntervalSince1970)
        let fresh = Date().timeIntervalSince(at) < 120  // les anciens messages reviennent à chaque reconnexion
        let who = String((m["name"] as? String ?? "Un pote").prefix(20))
        switch m["kind"] as? String {
        case "status":
            let state = BotState(rawValue: m["state"] as? String ?? "") ?? .idle
            let sessions = m["sessions"] as? Int ?? 0
            let presence = Presence(rawValue: m["presence"] as? String ?? "") ?? .active
            let since = (m["since"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? at
            let skin = m["skin"] as? String, color = m["color"] as? String
            let tint = (color?.isEmpty ?? true) ? nil : color
            if let f = list.first(where: { $0.id == id }) {
                // Arrivé sur son Mac : il était hors ligne, ou absent depuis plus de 30 min.
                // (Hors ligne depuis moins de 5 min : il a juste relancé l'app ou fermé le capot une minute.)
                let wasHere = f.online && (f.presence == .active || Date().timeIntervalSince(f.since) < 30 * 60)
                    || f.presence == .off && Date().timeIntervalSince(f.since) < 5 * 60
                if fresh && !wasHere && presence == .active { arrival(id, who, m["color"] as? String, f.mochi.skin.aura) }
                f.name = who
                if let skin, skin != f.mochi.skin.id { f.mochi.skin = Skin.named(skin) }
                f.mochi.tint = tint
                f.sessions = sessions
                f.seen = at
                f.presence = presence
                f.since = since
                f.cam = m["cam"] as? Bool ?? false
                f.dnd = m["dnd"] as? Bool ?? false
                f.note = String((m["note"] as? String ?? "").prefix(Self.noteLimit))
                f.music = (m["music"] as? String).map { String($0.prefix(80)) }
                f.musicID = Self.trackID(m["musicID"] as? String)
                if f.state != state { f.state = state; f.mochi.setState(state) }
            } else {
                let f = Friend(id: id, name: who, state: state, sessions: sessions, seen: at, presence: presence,
                               since: since, skin: skin, tint: tint)
                f.cam = m["cam"] as? Bool ?? false
                f.dnd = m["dnd"] as? Bool ?? false
                f.note = String((m["note"] as? String ?? "").prefix(Self.noteLimit))
                f.music = (m["music"] as? String).map { String($0.prefix(80)) }
                f.musicID = Self.trackID(m["musicID"] as? String)
                list.append(f)
                // Pas vu depuis plus de 6 h (le matin, après la nuit) : sa première nouvelle est une arrivée.
                if fresh && presence == .active { arrival(id, who, m["color"] as? String, f.mochi.skin.aura) }
            }
            list.sort { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
            objectWillChange.send()
            FriendCam.shared.friendsChanged()
        case "cam-watch", "cam-offer", "cam-answer", "cam-stop", "cam-call", "cam-call-ok", "cam-call-no", "cam-call-end":
            guard m["to"] as? String == me, Date().timeIntervalSince(at) < 60 else { return }
            FriendCam.shared.handle(m["kind"] as? String ?? "", from: id, name: who, m)
        case "poke":
            guard m["to"] as? String == me, fresh else { return }
            let heart = m["emote"] as? String == "heart"
            Store.shared.poked(heart: heart, from: who)
        case "chat":
            guard let body = m["text"] as? String, !body.isEmpty else { return }
            let mid = m["mid"] as? String ?? ev["id"] as? String ?? UUID().uuidString
            guard !chat.contains(where: { $0.id == mid }) else { return }
            add(Message(id: mid, from: id, name: who, text: String(body.prefix(500)), at: at, mine: false))
            if fresh && !Store.shared.chatVisible {
                unread += 1
                let f = list.first { $0.id == id }
                Store.shared.chatReceived(from: who, color: f?.mochi.tint ?? f?.mochi.skin.aura ?? "#FF8BC4", text: body)
            }
        case "react":
            guard let mid = m["mid"] as? String, let emoji = m["emoji"] as? String, Self.reactionEmojis.contains(emoji) else { return }
            setReaction(mid, emoji, by: id, on: m["on"] as? Bool ?? true)
        case "seen":
            guard let t = m["at"] as? Double else { return }
            let date = Date(timeIntervalSince1970: t)
            if date > (seenBy[id] ?? .distantPast) { seenBy[id] = date }
        default:
            break
        }
    }

    // MARK: Diagnostic (socket : EncocheFriendTest)

    /// Fait comme si un message arrivait du groupe (sans passer par ntfy), ouvre ou ferme l'onglet Potes, et
    /// rend l'état de la caméra entre potes. Sert à essayer la caméra avec un faux pote, sur ce Mac seulement.
    func diagnose(_ ev: [String: Any]) -> [String: Any] {
        if var m = ev["message"] as? [String: Any] {
            m["app"] = "encoche"
            if let text = try? JSONSerialization.data(withJSONObject: m),
               let line = try? JSONSerialization.data(withJSONObject: ["event": "message", "time": Date().timeIntervalSince1970,
                                                                        "message": String(decoding: text, as: UTF8.self)]) {
                receive(line)
            }
        }
        if let open = ev["open"] as? Bool {
            let store = Store.shared
            if open {
                store.friendsShowsChat = false
                store.show(.friends)
                store.pinUntil = Date().addingTimeInterval(40)  // reste ouverte sans la souris
            } else {
                store.collapse()
            }
        }
        if ev["restart"] as? Bool == true { restart() }
        let mine: [String: Any] = ["me": me, "friends": list.map { "\($0.name) cam=\($0.cam)" }]
        return mine.merging(FriendCam.shared.diagnose()) { a, _ in a }
    }

    func say(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if self.notice == text { self.notice = nil } }
    }
}
