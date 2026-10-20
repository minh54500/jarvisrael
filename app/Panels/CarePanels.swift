import AppKit
import SwiftUI

// Rappels du bonhomme et visite guidée.

/// Rappel du bonhomme : pause, eau, nuit, batterie, chaleur.
struct CarePanel: View {
    @ObservedObject var store: Store

    var body: some View {
        let r = store.reminder ?? .pause
        Card(wash: Color(hex: tint(r), 0.4)) {
            VStack(alignment: .leading, spacing: 8) {
                big(title(r))
                sub(detail(r))
                HStack(spacing: 8) {
                    switch r {
                    case .pause:
                        Button("C'est fait") { store.answerReminder(later: false) }.buttonStyle(Pill(primary: true))
                        Button("Dans 10 min") { store.answerReminder(later: true) }.buttonStyle(Pill())
                    case .heat:
                        Button("Voir les Outils") { store.openTool(.servers) }.buttonStyle(Pill(primary: true))
                        Button("OK") { store.answerReminder(later: false) }.buttonStyle(Pill())
                    default:
                        Button(r == .water ? "C'est fait" : "OK") { store.answerReminder(later: false) }.buttonStyle(Pill(primary: true))
                    }
                    Spacer()
                    Button("Couper les rappels") {
                        Care.shared.enabled = false
                        store.collapse()
                    }
                    .buttonStyle(.plain)
                    .font(Fonts.caption)
                    .foregroundStyle(Color.faint)
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
    }

    private func title(_ r: Reminder) -> String {
        switch r {
        case .pause: "Ça fait 50 min que tu codes."
        case .water: "Un verre d'eau ?"
        case .night(let h): "Il est \(h) h du matin."
        case .battery(let b): "Batterie à \(b) %."
        case .heat: "Ton Mac chauffe."
        }
    }

    private func detail(_ r: Reminder) -> String {
        switch r {
        case .pause: "Lève-toi, étire-toi, regarde au loin 20 secondes."
        case .water: "Ton cerveau code mieux hydraté."
        case .night: "Claude peut continuer demain. Toi, tu devrais dormir."
        case .battery: "Branche ton Mac avant qu'il coupe en plein build."
        case .heat: "Un build ou un serveur tourne fort ? Jette un œil."
        }
    }

    private func tint(_ r: Reminder) -> String {
        switch r {
        case .pause: "#A78BFA"
        case .water: "#38BDF8"
        case .night: "#6366F1"
        case .battery, .heat: "#F4505E"
        }
    }
}

/// Visite guidée : cinq étapes, au premier lancement (et depuis les Réglages).
struct WelcomePanel: View {
    @ObservedObject var store: Store

    var body: some View {
        Card(wash: Color(hex: "#FF8BC4", 0.2)) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    switch store.welcomeStep {
                    case 0:
                        big("Salut ! Moi, c'est le bonhomme d'Encoche.")
                        sub("Je vis dans ton encoche et je garde un œil sur Claude Code pour toi : ce qu'il fait, quand il a fini, quand il attend.")
                    case 1:
                        big(store.hooked ? "Je suis branché à Claude Code ✓" : "Branche-moi à Claude Code.")
                        sub("Tes sessions (VS Code ou Terminal) apparaissent ici, et tu autorises ou réponds à Claude sans quitter ce que tu fais.")
                        if !store.hooked { Button("Brancher à Claude Code") { store.setHooked(true) }.buttonStyle(Pill(primary: true)) }
                    case 2:
                        big("Tes raccourcis")
                        VStack(alignment: .leading, spacing: 3) {
                            key("⌥ Espace", "écrire à Claude"); key("⌥⇧ Espace", "lui dicter")
                            key("⌥⇧ R", "l'IA sur un texte sélectionné"); key("⌥⇧ Y / N", "autoriser ou refuser")
                        }
                    case 3:
                        big("Les onglets, en haut")
                        sub("Claude (sessions, plan, usage) · Musique · Étagère (fichiers, copies) · Outils (terminal, texte IA, miroir, prompteur) · Potes.")
                    default:
                        big("C'est parti !")
                        sub("Survole l'encoche quand tu veux. Clic droit sur moi : skins, couleurs, réglages.")
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        ForEach(0..<Store.welcomeSteps, id: \.self) { i in
                            Circle().fill(i == store.welcomeStep ? Color.ink : Color.faint.opacity(0.5)).frame(width: 6, height: 6)
                        }
                    }
                    Spacer()
                    if store.welcomeStep + 1 < Store.welcomeSteps {
                        Button("Passer") { store.finishWelcome() }.buttonStyle(.plain).font(Fonts.caption).foregroundStyle(Color.faint)
                    }
                    Button(store.welcomeStep + 1 < Store.welcomeSteps ? "Suivant" : "Terminer") { store.nextWelcome() }
                        .buttonStyle(Pill(primary: true))
                }
            }
            .id(store.welcomeStep)
            .transition(.opacity)
            .padding(.leading, 100)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
        }
    }

    private func key(_ k: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).frame(height: 19)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.1)))
            Text(what).font(Fonts.label).foregroundStyle(Color.soft)
        }
    }
}
