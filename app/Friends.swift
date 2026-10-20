import AppKit

/// Entre potes : chacun partage l'humeur de son bonhomme dans un groupe (un sujet ntfy secret que
/// vous partagez), et voit celle des autres. Seuls le pseudo et l'état sont envoyés (jamais les projets
/// ni les messages). Un clic sur le bonhomme d'un pote lui envoie un cœur ou un coucou.
@MainActor
final class Friends: NSObject, ObservableObject, URLSessionDataDelegate {
    static let shared = Friends()
    static let server = "https://ntfy.sh"

    final class Friend: Identifiable {
        let id: String
        var name: String
        var state: BotState
        var sessions: Int
        var seen: Date
        let mochi: Mochi
        var online: Bool { Date().timeIntervalSince(seen) < 70 * 60 }  // un signe de vie toutes les 30 min

        init(id: String, name: String, state: BotState, sessions: Int, seen: Date) {
            self.id = id; self.name = name; self.state = state; self.sessions = sessions; self.seen = seen
            let colors = ["#FF8BC4", "#38BDF8", "#34D399", "#F7B32B", "#A78BFA", "#F472B6", "#2DD4A7"]
            let pick = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % colors.count
            mochi = Mochi(bodyColor: colors[pick], now: CACurrentMediaTime())
            mochi.setState(state, force: true)
        }
    }

    @Published private(set) var list: [Friend] = []
    @Published private(set) var notice: String?

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
    private var sent: (state: String, at: Date)?
    private var pending: Timer?
    private var heartbeat: Timer?
    private var current = (state: BotState.idle, sessions: 0)
    private var lastPoke = Date.distantPast

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
    private var restartTimer: Timer?

    /// (Re)branche le groupe selon les réglages.
    func restart() {
        task?.cancel()
        task = nil
        heartbeat?.invalidate()
        list = []
        sent = nil
        guard configured else { return }
        connect()
        publish(force: true)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Friends.shared.publish(force: true) }
        }
    }

    // MARK: Ce que je partage

    /// Appelé quand l'humeur du bonhomme change. Au plus un message toutes les 30 s (ntfy gratuit
    /// limite le nombre de messages par jour) : les changements rapprochés sont regroupés.
    func share(_ state: BotState, sessions: Int) {
        current = (state == .finished || state == .dizzy ? .idle : state, sessions)
        guard configured, sent?.state != current.state.rawValue, pending == nil else { return }
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
        guard configured, force || sent?.state != current.state.rawValue else { return }
        sent = (current.state.rawValue, Date())
        post(["kind": "status", "state": current.state.rawValue, "sessions": current.sessions])
    }

    /// Un cœur (« heart ») ou un coucou (« wave ») au bonhomme d'un pote.
    func poke(_ f: Friend, _ emote: String) {
        guard configured, Date().timeIntervalSince(lastPoke) > 2 else { return }
        lastPoke = Date()
        post(["kind": "poke", "to": f.id, "emote": emote])
        Sound.shared.play("pop")
        say(emote == "heart" ? "Cœur envoyé à \(f.name) ✓" : "Coucou envoyé à \(f.name) ✓")
    }

    private func post(_ fields: [String: Any]) {
        var payload = fields
        payload["app"] = "encoche"
        payload["v"] = 1
        payload["id"] = me
        payload["name"] = name
        guard let body = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: body, encoding: .utf8),
              let url = URL(string: Self.server) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Priorité minimale : si quelqu'un s'abonne au groupe sur son téléphone, ça ne sonne pas.
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["topic": group, "message": text, "priority": 1, "tags": ["encoche"]])
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: Ce que je reçois (flux ntfy : une ligne JSON par message)

    private func connect() {
        guard configured, let topic = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(Self.server)/\(topic)/json?since=2h") else { return }
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
        let who = String((m["name"] as? String ?? "Un pote").prefix(20))
        switch m["kind"] as? String {
        case "status":
            let state = BotState(rawValue: m["state"] as? String ?? "") ?? .idle
            let sessions = m["sessions"] as? Int ?? 0
            if let f = list.first(where: { $0.id == id }) {
                f.name = who
                f.sessions = sessions
                f.seen = at
                if f.state != state { f.state = state; f.mochi.setState(state) }
            } else {
                list.append(Friend(id: id, name: who, state: state, sessions: sessions, seen: at))
            }
            list.sort { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
            objectWillChange.send()
        case "poke":
            // Les anciens messages reviennent à la reconnexion : un coucou de plus d'une minute est ignoré.
            guard m["to"] as? String == me, Date().timeIntervalSince(at) < 60 else { return }
            let heart = m["emote"] as? String == "heart"
            say(heart ? "\(who) t'envoie un cœur" : "\(who) te fait coucou")
            Store.shared.poked(heart: heart)
        default:
            break
        }
    }

    private func say(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if self.notice == text { self.notice = nil } }
    }
}
