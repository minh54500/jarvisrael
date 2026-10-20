import AppKit

/// Notifications sur le téléphone via ntfy (app gratuite, iOS et Android) : Claude a fini, attend une
/// autorisation ou s'est arrêté. Rien n'est envoyé tant qu'aucun sujet n'est choisi dans les réglages.
/// Le message reste court (nom du projet, sans le contenu de tes demandes) : un sujet ntfy est public
/// pour qui en connaît le nom.
enum Phone {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "ntfy.on") }
    static var topic: String { (UserDefaults.standard.string(forKey: "ntfy.topic") ?? "").trimmingCharacters(in: .whitespaces) }
    /// Par défaut, seulement quand personne n'a touché le Mac depuis 2 minutes.
    static var onlyAway: Bool { UserDefaults.standard.object(forKey: "ntfy.away") as? Bool ?? true }

    static func notify(_ title: String, _ message: String, tag: String) {
        guard enabled, !topic.isEmpty else { return }
        if onlyAway {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            guard idle > 120 else { return }
        }
        post(title, message, tag: tag)
    }

    /// Envoi direct (bouton « Tester » des réglages).
    static func post(_ title: String, _ message: String, tag: String) {
        guard !topic.isEmpty, let url = URL(string: "https://ntfy.sh/") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["topic": topic, "title": title, "message": message, "tags": [tag]])
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Un sujet difficile à deviner.
    static func newTopic() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "encoche-" + String((0..<12).map { _ in chars.randomElement()! })
    }
}
