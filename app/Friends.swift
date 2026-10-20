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
    }

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
           let saved = try? JSONDecoder().decode([Message].self, from: data) { chat = saved }
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
        // Autre groupe : on repart d'un chat vide.
        if UserDefaults.standard.string(forKey: "friends.chatGroup") != group {
            UserDefaults.standard.set(group, forKey: "friends.chatGroup")
            chat = []
            unread = 0
            saveChat()
        }
        guard configured else { return }
        presence = .active
        presenceSince = Date()
        connect()
        publish(force: true)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Friends.shared.publish(force: true) }
        }
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
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
        presence = .off
        presenceSince = Date()
        let done = DispatchSemaphore(value: 0)
        post(status(), then: { done.signal() })
        _ = done.wait(timeout: .now() + 1.5)
        sent = (signature, Date())
    }

    private var signature: String {
        "\(current.state.rawValue)|\(presence.rawValue)|\(Skin.current.id)|\(Skin.tint ?? "")|\(name)"
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
         "color": Skin.tint ?? "", "presence": presence.rawValue, "since": presenceSince.timeIntervalSince1970]
    }

    /// Un cœur (« heart ») ou un coucou (« wave ») au bonhomme d'un pote.
    func poke(_ f: Friend, _ emote: String) {
        guard configured, Date().timeIntervalSince(lastPoke) > 2 else { return }
        lastPoke = Date()
        post(["kind": "poke", "to": f.id, "emote": emote])
        Sound.shared.play("pop")
        say(emote == "heart" ? "Cœur envoyé à \(f.name) ✓" : "Coucou envoyé à \(f.name) ✓")
    }

    // MARK: Chat

    func sendChat() {
        let text = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard configured, !text.isEmpty else { return }
        let id = UUID().uuidString
        post(["kind": "chat", "text": text, "mid": id])
        add(Message(id: id, from: me, name: name, text: text, at: Date(), mine: true))
        draft = ""
        Sound.shared.play("pop")
    }

    func markRead() { if unread != 0 { unread = 0 } }

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

    private func post(_ fields: [String: Any], then done: (() -> Void)? = nil) {
        var payload = fields
        payload["app"] = "encoche"
        payload["v"] = 1
        payload["id"] = me
        payload["name"] = name
        guard let body = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: body, encoding: .utf8),
              let url = URL(string: Self.server) else { done?(); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Priorité minimale : si quelqu'un s'abonne au groupe sur son téléphone, ça ne sonne pas.
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["topic": group, "message": text, "priority": 1, "tags": ["encoche"]])
        URLSession.shared.dataTask(with: req) { _, _, _ in done?() }.resume()
    }

    // MARK: Ce que je reçois (flux ntfy : une ligne JSON par message)

    private func connect() {
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
                f.name = who
                if let skin, skin != f.mochi.skin.id { f.mochi.skin = Skin.named(skin) }
                f.mochi.tint = tint
                f.sessions = sessions
                f.seen = at
                f.presence = presence
                f.since = since
                if f.state != state { f.state = state; f.mochi.setState(state) }
            } else {
                list.append(Friend(id: id, name: who, state: state, sessions: sessions, seen: at, presence: presence,
                                   since: since, skin: skin, tint: tint))
            }
            list.sort { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
            objectWillChange.send()
        case "poke":
            guard m["to"] as? String == me, fresh else { return }
            let heart = m["emote"] as? String == "heart"
            say(heart ? "\(who) t'envoie un cœur" : "\(who) te fait coucou")
            Store.shared.poked(heart: heart)
        case "chat":
            guard let body = m["text"] as? String, !body.isEmpty else { return }
            let mid = m["mid"] as? String ?? ev["id"] as? String ?? UUID().uuidString
            guard !chat.contains(where: { $0.id == mid }) else { return }
            add(Message(id: mid, from: id, name: who, text: String(body.prefix(500)), at: at, mine: false))
            if fresh && !Store.shared.chatVisible {
                unread += 1
                Store.shared.chatReceived(from: who, text: body)
            }
        default:
            break
        }
    }

    private func say(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if self.notice == text { self.notice = nil } }
    }
}
