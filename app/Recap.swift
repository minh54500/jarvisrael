import Foundation

/// Le résumé de ta journée : ce que tu as demandé à Claude aujourd'hui (l'historique de Claude Code) et les
/// commits du jour, projet par projet, résumés par Claude en quelques points. Pratique pour un client.
@MainActor
final class Recap: ObservableObject {
    static let shared = Recap()

    @Published private(set) var text = ""
    @Published private(set) var busy = false
    @Published private(set) var day = Date()

    func make() {
        guard !busy else { return }
        busy = true
        text = ""
        day = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let facts = Self.gather()
            guard !facts.isEmpty else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Recap.shared.busy = false
                        Recap.shared.text = "Rien trouvé pour aujourd'hui : pas de session Claude ni de commit."
                    }
                }
                return
            }
            let system = "Tu écris le résumé de la journée de travail d'un freelance, en français, simple et sans jargon. "
                + "Pour chaque projet : son nom en gras, puis 2 à 4 tirets courts sur ce qui a été fait. "
                + "Termine par « À reprendre demain » avec 1 à 3 tirets si quelque chose semble en cours. Rien d'autre."
            Claude.run(prompt: facts, system: system, model: "sonnet") { lines in
                let out = lines.first ?? ""
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Recap.shared.busy = false
                        Recap.shared.text = out.isEmpty ? "Claude n'a pas répondu. Claude Code est-il installé et connecté ?" : out
                        Sound.shared.play(out.isEmpty ? "error" : "finish")
                    }
                }
            }
        }
    }

    /// Les faits du jour, projet par projet : demandes faites à Claude, commits.
    nonisolated private static func gather() -> String {
        let fm = FileManager.default
        let start = Calendar.current.startOfDay(for: Date())
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        var prompts: [String: [String]] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                guard let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, mod >= start,
                      let data = try? Data(contentsOf: file) else { continue }
                var cwd: String?
                for line in data.split(separator: 0x0A) {
                    guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if let c = o["cwd"] as? String { cwd = c }
                    guard o["type"] as? String == "user", o["isMeta"] as? Bool != true,
                          let ts = (o["timestamp"] as? String).flatMap({ iso.date(from: $0) }), ts >= start,
                          let m = o["message"] as? [String: Any], let text = m["content"] as? String else { continue }
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:"), let cwd else { continue }
                    prompts[cwd, default: []].append(String(t.replacingOccurrences(of: "\n", with: " ").prefix(200)))
                }
            }
        }
        var out = ""
        for (cwd, list) in prompts.sorted(by: { $0.key < $1.key }) {
            out += "## \(URL(fileURLWithPath: cwd).lastPathComponent)\nDemandes à Claude :\n"
            out += list.suffix(25).map { "- \($0)" }.joined(separator: "\n") + "\n"
            if let commits = git(cwd, ["log", "--since=midnight", "--format=%s"]), !commits.isEmpty {
                out += "Commits :\n" + commits.split(separator: "\n").prefix(20).map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            out += "\n"
        }
        return String(out.prefix(30_000))
    }

    nonisolated private static func git(_ dir: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}
