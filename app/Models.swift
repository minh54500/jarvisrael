import Foundation
import SwiftUI

// Les données de l'encoche : sessions Claude, tâches, bilans, modèles, demandes, bulles, panneaux.
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
    var agents: [String: String] = [:]  // sous-agents au travail (identifiant → type)
    var background = false  // la demande est finie, mais des agents bossent encore en arrière-plan

    var plan: (done: Int, total: Int)? {
        todos.isEmpty ? nil : (todos.filter { $0.status == "completed" }.count, todos.count)
    }
    var currentTodo: Todo? { todos.first { $0.status == "in_progress" } }
    var inApp: Bool { ["claude-desktop", "claude-desktop-3p", "local-agent"].contains(entrypoint) }  // lancée depuis l'app Claude

    /// Où vit la session, pour les boutons « Voir dans … ».
    var place: String {
        if entrypoint == "claude-vscode" { return "VS Code" }
        if inApp { return "l'app Claude" }
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
    /// Une autorisation d'outil, une question de Claude (choix à cliquer) ou son plan à valider.
    enum Kind { case tool, question, plan }

    let id = UUID()
    let session: String
    let title: String
    let detail: String
    let responder: Responder
    let at = Date()
    var kind = Kind.tool
    var input: [String: Any] = [:]
    var agent: String?   // sous-agent qui demande (nil : Claude lui-même)

    /// Les questions (AskUserQuestion) : texte, options, choix multiple.
    var questions: [(question: String, header: String, options: [(label: String, detail: String)], multi: Bool)] {
        (input["questions"] as? [[String: Any]] ?? []).map { q in
            (q["question"] as? String ?? "", q["header"] as? String ?? "",
             (q["options"] as? [[String: Any]] ?? []).map { ($0["label"] as? String ?? "", $0["description"] as? String ?? "") },
             q["multiSelect"] as? Bool ?? false)
        }
    }
    var plan: String { input["plan"] as? String ?? "" }
}

/// peek : l'encoche s'élargit un instant pour une bulle (message d'un pote…), sans s'ouvrir.
enum Mode { case hidden, compact, peek, expanded }

/// Bulle de notification : qui (couleur, initiale ou icône), quoi, et le panneau qu'un clic ouvre.
struct Toast: Equatable {
    let id = UUID()
    var icon: String?      // symbole ; sinon l'initiale de `title`
    var color: String
    var title: String
    var text: String
    var opensChat = false
    var opensUpdate = false  // nouvelle version d'Encoche : un clic ouvre la mise à jour
    var opens: Panel?        // une nouvelle de Claude arrivée pendant que tu écrivais : un clic l'ouvre…
    var session: String?     // …sur la bonne session
}
enum Panel: Equatable { case greeting, overview, empty, approval, finished, error, upload, choose, converting, result, shelf, music, dev, care, todos, friends, projects, recap, welcome }

let PALETTE = ["#FF6B5B", "#2DD4A7", "#F7B32B", "#A78BFA", "#38BDF8", "#F472B6"]
