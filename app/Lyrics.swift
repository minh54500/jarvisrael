import Foundation

/// Paroles synchronisées du morceau Spotify en cours, depuis LRCLIB (base libre et gratuite, sans compte).
@MainActor
final class Lyrics: ObservableObject {
    static let shared = Lyrics()

    @Published private(set) var lines: [(time: Double, text: String)] = []
    @Published private(set) var loadedFor = ""
    private var loading = ""

    /// Les paroles de ce morceau (une fois par morceau).
    func load(_ t: Spotify.Track) {
        guard !t.id.isEmpty, t.id != loadedFor, t.id != loading else { return }
        loading = t.id
        lines = []
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "artist_name", value: t.artist), URLQueryItem(name: "track_name", value: t.name),
                        URLQueryItem(name: "album_name", value: t.album), URLQueryItem(name: "duration", value: String(Int(t.duration)))]
        guard let url = c.url else { return }
        var req = URLRequest(url: url)
        req.setValue("Encoche (https://github.com/minh54500/jarvisrael)", forHTTPHeaderField: "User-Agent")
        let id = t.id, artist = t.artist, name = t.name
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let synced = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["syncedLyrics"] as? String {
                return Self.deliver(synced, for: id)
            }
            // Durée un peu différente : recherche plus large, lancée comme une deuxième requête (jamais attendue ici).
            Self.search(artist: artist, track: name) { Self.deliver($0 ?? "", for: id) }
        }.resume()
    }

    nonisolated private static func deliver(_ lrc: String, for id: String) {
        let parsed = parse(lrc)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let l = Lyrics.shared
                guard l.loading == id else { return }
                l.lines = parsed
                l.loadedFor = id
                l.loading = ""
            }
        }
    }

    /// La ligne en cours et la suivante, à cette position du morceau.
    func at(_ position: Double) -> (current: String, next: String)? {
        guard let i = lines.lastIndex(where: { $0.time <= position + 0.3 }) else { return lines.isEmpty ? nil : ("", lines[0].text) }
        return (lines[i].text, i + 1 < lines.count ? lines[i + 1].text : "")
    }

    /// Recherche plus large (même titre et artiste, durée différente) : le premier résultat synchronisé.
    nonisolated private static func search(artist: String, track: String, done: @escaping @Sendable (String?) -> Void) {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "track_name", value: track)]
        guard let url = c.url else { return done(nil) }
        var req = URLRequest(url: url)
        req.setValue("Encoche (https://github.com/minh54500/jarvisrael)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let list = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            done(list.lazy.compactMap { $0["syncedLyrics"] as? String }.first)
        }.resume()
    }

    /// « [01:23.45] paroles » → (83.45, « paroles »).
    nonisolated static func parse(_ lrc: String) -> [(time: Double, text: String)] {
        lrc.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { return nil }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return (m * 60 + s, text.isEmpty ? "♪" : text)
        }
    }
}
