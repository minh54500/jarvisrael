import AppKit
import SwiftUI

// Onglet Claude : sessions, écrire à Claude, autorisations, questions et plan, bilan, projets, résumé du jour.

struct EmptyPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: .white.opacity(0.08)) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    big("Rien ne tourne pour l'instant.")
                    sub(store.hooked ? "Lance Claude Code dans VS Code, ou glisse un fichier sur moi."
                                     : "Branche-moi à Claude Code pour suivre tes sessions d'ici.")
                }
                Spacer()
                if !store.hooked {
                    Button("Brancher à Claude Code") { store.setHooked(true) }.buttonStyle(Pill(primary: true))
                } else {
                    Button("Projets récents") { store.goTo(.projects) }.buttonStyle(Pill(primary: true))
                }
            }
            .padding(.leading, 110)
            .padding(.trailing, 18)
        }
    }
}

struct OverviewPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Who(session: store.focused, suffix: "")
                        ModelMenu(store: store)
                        if let n = store.focused?.agents.count, n > 0 {
                            Label("\(n)", systemImage: "person.2.wave.2.fill")
                                .font(Fonts.caption.weight(.semibold)).foregroundStyle(Color(hex: "#7CC7FF"))
                                .help(store.focused?.agents.values.sorted().joined(separator: ", ") ?? "")
                                .accessibilityLabel("\(n) sous-agent\(n > 1 ? "s" : "") au travail")
                        }
                        Spacer(minLength: 4)
                        if let s = store.focused {
                            Button { store.jump(to: s) } label: {
                                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(IconButton())
                            .help("Ouvrir dans \(s.place)")
                            .accessibilityLabel("Ouvrir \(s.name) dans \(s.place)")
                        }
                        Button { store.goTo(.projects) } label: {
                            Image(systemName: "folder").font(.system(size: 10.5, weight: .bold))
                        }
                        .buttonStyle(IconButton())
                        .help("Projets récents : reprendre ou lancer une session")
                        .accessibilityLabel("Projets récents")
                    }
                    if let notice = store.notice {
                        Text(notice.text)
                            .font(Fonts.lead)
                            .foregroundStyle(notice.ok ? Color.success : Color.danger)
                            .lineLimit(2)
                            .transition(.opacity)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            // Avec un plan, la ligne du haut devient son avancement (clic : la liste complète).
                            let plan = store.focused?.plan
                            if let plan { PlanLine(store: store, done: plan.done, total: plan.total) }
                            let lines = Array((store.focused?.history ?? []).suffix(plan == nil ? 2 : 1))
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                let current = i == lines.count - 1
                                Text(current ? (store.focused?.line ?? line) : line)
                                    .font(current ? Fonts.lead : Fonts.label)
                                    .foregroundStyle(current ? Color.ink : Color.faint)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if lines.isEmpty { Text(store.focused?.line ?? "").foregroundStyle(Color.muted) }
                        }
                        .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    FavoritesRow(store: store)
                    ComposeBar(store: store)
                }
                .animation(.easeOut(duration: 0.2), value: store.notice?.text)
                .padding(.leading, 100)
                .padding(.trailing, 10)
                .padding(.vertical, 11)
            }
            .frame(width: 356)
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.sessions.prefix(store.sessions.count > 3 ? 3 : 4)) { s in
                        SessionRow(session: s, chosen: s.id == store.focused?.id, state: label(s.state)) { store.select(s) }
                    }
                    Spacer(minLength: 0)
                    UsageStrip()
                }
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func label(_ s: BotState) -> String {
        switch s {
        case .working: "travaille"
        case .approval: "à autoriser"
        case .waiting: "attend ta réponse"
        case .finished: "terminé"
        case .error: "erreur"
        case .sleeping, .idle, .dizzy: "au repos"
        }
    }
}

/// Le modèle de la session choisie, en pastille ; un clic propose les autres.
struct ModelMenu: View {
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        let current = store.focused?.model ?? ""
        let shown = current.isEmpty ? store.defaultModel : current
        let vscode = store.focused?.entrypoint == "claude-vscode"
        Menu {
            // Terminal : `/model nom` change la session. VS Code : son choix de modèle est une action de
            // son interface, on ouvre donc la session pour le faire là-bas.
            if let s = store.focused, !vscode {
                Section("Cette session (\(s.name))") {
                    ForEach(ClaudeModel.all) { m in
                        Button { store.setModel(m) } label: { check(m.name, m.arg == current) }
                    }
                }
            }
            Section("Nouvelles sessions") {
                ForEach(ClaudeModel.all) { m in
                    Button { store.setDefaultModel(m) } label: { check(m.name, isDefault(m)) }
                }
            }
            if let s = store.focused, vscode {
                Divider()
                Button("Changer celle-ci dans VS Code (/model)…") { store.jump(to: s) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(shown.isEmpty ? "Modèle" : ClaudeModel.label(shown)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Fonts.caption.weight(.medium))
            .foregroundStyle(hover ? Color.ink : Color.soft)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(hover ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.focused == nil || store.sending)
        .onHover { hover = $0 }
        .help("Modèle de Claude : cette session, ou les nouvelles")
        .accessibilityLabel("Modèle : \(shown.isEmpty ? "inconnu" : ClaudeModel.label(shown))")
    }

    @ViewBuilder private func check(_ name: String, _ on: Bool) -> some View {
        if on { Label(name, systemImage: "checkmark") } else { Text(name) }
    }

    /// Le réglage peut être un nom court (« opus ») ou complet (« claude-opus-5-5 »).
    private func isDefault(_ m: ClaudeModel) -> Bool {
        let d = store.defaultModel.lowercased()
        return !d.isEmpty && (m.arg == d || m.arg.contains("-\(d)-"))
    }
}

/// « Session 5 h ▰▰▱ 18 % · ↻ 16:40 » et « Semaine 6 % » : l'usage de l'abonnement Claude.
struct UsageStrip: View {
    @ObservedObject var usage = Usage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let f = usage.fiveHour { row("Session 5 h", f) }
            if let w = usage.week { row("Semaine", w) }
            if usage.fiveHour == nil && usage.week == nil {
                Text("Usage Claude : je regarde…").font(Fonts.caption).foregroundStyle(Color.faint)
            }
        }
        .onAppear { usage.refreshIfStale() }
        .help(usage.updated.map { "Mis à jour à \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
    }

    private func row(_ label: String, _ w: Usage.Window) -> some View {
        let tint: Color = w.used >= 0.8 ? .danger : w.used >= 0.5 ? .warning : .success
        let reset = Calendar.current.isDateInToday(w.resets) ? w.resets.formatted(date: .omitted, time: .shortened)
            : w.resets.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return HStack(spacing: 6) {
            Text(label).foregroundStyle(Color.muted).frame(width: 66, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(tint).frame(width: max(3, g.size.width * min(1, w.used)))
                }
            }
            .frame(height: 4)
            Text("\(Int((w.used * 100).rounded())) %").monospacedDigit().foregroundStyle(Color.soft).frame(width: 34, alignment: .trailing)
        }
        .font(Fonts.caption)
        .help("Repart à zéro : \(reset)")
        .accessibilityLabel("\(label) : \(Int(w.used * 100)) pour cent utilisés, repart à zéro \(reset)")
    }
}

/// Une session dans la liste de droite : sa couleur, son nom, son état en pastille.
struct SessionRow: View {
    let session: Session
    let chosen: Bool
    let state: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let tint = Color(hex: STYLES[session.state]?.col ?? "#9A9FA8")
        let busy = session.state == .working || session.state == .approval || session.state == .waiting
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: session.color)).frame(width: 8, height: 8)
                Text(session.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    if busy { PulseDot(color: tint) }
                    Text(state).lineLimit(1)
                }
                .font(Fonts.caption)
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(tint.opacity(0.12)))
            }
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous)
                .fill(.white.opacity(chosen ? 0.12 : hover ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).strokeBorder(.white.opacity(chosen ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .help("Écrire à \(session.name)")
        .accessibilityLabel("\(session.name), \(state)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Prompts favoris : un clic les envoie ; « + » garde le message en cours ; clic droit pour retirer.
struct FavoritesRow: View {
    @ObservedObject var store: Store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(store.favorites, id: \.self) { text in
                    Button(text) { store.sendFavorite(text) }
                        .buttonStyle(Chip())
                        .disabled(store.sending || store.focused == nil)
                        .help("Envoyer « \(text) » à Claude")
                        .contextMenu { Button("Retirer des favoris") { store.removeFavorite(text) } }
                }
                Button { store.addFavorite() } label: { Image(systemName: "plus").font(.system(size: 9.5, weight: .bold)) }
                    .buttonStyle(Chip())
                    .help("Garder le message en cours comme favori")
                    .accessibilityLabel("Ajouter le message aux favoris")
            }
        }
        .frame(height: 22)
    }
}

/// Champ « Écris à Claude… » et bouton d'envoi, en bas de la section de gauche.
struct ComposeBar: View {
    @ObservedObject var store: Store
    @ObservedObject var voice = Voice.shared
    var body: some View {
        let empty = store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 6) {
            ComposeField(text: $store.draft,
                         placeholder: voice.listening ? "Je t'écoute…"
                             : store.focused.map { "Écris à Claude (\($0.name))…" } ?? "Écris à Claude…",
                         onSubmit: { store.submitDraft() },
                         onEditing: { store.setComposing($0) },
                         focus: store.wantsFocus,
                         onFocused: { store.wantsFocus = false })
                .frame(height: 18)
            Button { store.capture() } label: { Image(systemName: "viewfinder").font(.system(size: 11.5, weight: .semibold)) }
                .buttonStyle(MiniIcon())
                .help("Capturer une zone de l'écran et la montrer à Claude")
                .accessibilityLabel("Capture d'écran pour Claude")
            Button { store.toggleDictation() } label: {
                Image(systemName: voice.listening ? "waveform" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: voice.listening)
                    .foregroundStyle(voice.listening ? Color.danger : Color.muted)
            }
            .buttonStyle(MiniIcon())
            .help(voice.listening ? "Arrêter la dictée" : "Dicter le message (⌥⇧Espace)")
            .accessibilityLabel(voice.listening ? "Arrêter la dictée" : "Dicter le message")
            Button { store.submitDraft() } label: {
                Group {
                    if store.sending { ProgressView().controlSize(.mini).tint(Color.onLight) }
                    else { Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)) }
                }
                .foregroundStyle(Color.onLight)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.ink))
            }
            .buttonStyle(.plain)
            .opacity(empty && !store.sending ? 0.3 : 1)
            .disabled(empty || store.sending)
            .help("Envoyer à Claude (Entrée)")
            .accessibilityLabel("Envoyer à Claude")
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(store.composing ? 0.11 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(voice.listening ? Color.danger.opacity(0.5) : .white.opacity(store.composing ? 0.16 : 0.04)))
        .animation(.easeOut(duration: 0.15), value: store.composing)
    }
}

/// « ▰▰▰▱▱ 3/7 · Écrit les tests » : l'avancement du plan de Claude, clic pour la liste.
struct PlanLine: View {
    @ObservedObject var store: Store
    let done: Int
    let total: Int

    var body: some View {
        Button { store.goTo(.todos) } label: {
            HStack(spacing: 7) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(Color.success).frame(width: max(3, g.size.width * Double(done) / Double(max(1, total))))
                    }
                }
                .frame(width: 34, height: 4)
                Text("\(done)/\(total)").font(Fonts.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Color.soft)
                Text(store.focused?.currentTodo?.activeForm ?? (done == total ? "Plan terminé" : "Plan de Claude"))
                    .font(Fonts.label).foregroundStyle(Color.muted).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverDim())
        .help("Voir la liste des tâches de Claude")
    }
}

/// Le plan de Claude : ses tâches, cochées au fur et à mesure.
struct TodosPanel: View {
    @ObservedObject var store: Store

    var body: some View {
        Card(wash: Color(hex: "#34D399", 0.22)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Who(session: store.focused, suffix: "plan de Claude")
                    Spacer()
                    if let p = store.focused?.plan {
                        Text("\(p.done)/\(p.total)").font(Fonts.labelBold).monospacedDigit().foregroundStyle(Color.soft)
                    }
                }
                if let todos = store.focused?.todos, !todos.isEmpty {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(todos.enumerated()), id: \.offset) { _, t in TodoRow(todo: t) }
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                    Text("Pas de plan pour l'instant.").font(Fonts.lead)
                    Text("Quand Claude découpe une demande en étapes, elles s'affichent ici.").font(Fonts.label).foregroundStyle(Color.muted)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
        }
    }
}

struct TodoRow: View {
    let todo: Todo

    var body: some View {
        let done = todo.status == "completed", now = todo.status == "in_progress"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.success) }
                else if now { PulseDot(color: .success).frame(width: 12) }
                else { Image(systemName: "circle").foregroundStyle(Color.faint) }
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 14)
            Text(now && !todo.activeForm.isEmpty ? todo.activeForm : todo.content)
                .font(now ? Fonts.lead : Fonts.label)
                .foregroundStyle(done ? Color.faint : now ? Color.ink : Color.soft)
                .strikethrough(done, color: Color.faint)
                .lineLimit(1)
        }
    }
}

/// Une question de Claude : un clic sur une réponse (ou « Autre » pour écrire la sienne). Plusieurs
/// questions : l'une après l'autre ; choix multiple : on coche, puis Valider.
struct QuestionView: View {
    @ObservedObject var store: Store
    let permission: Permission
    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var picked = Set<String>()
    @State private var other = ""
    @State private var writing = false
    @State private var focusOther = false

    var body: some View {
        let qs = permission.questions
        let q = qs.indices.contains(index) ? qs[index] : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Who(session: store.session(permission.session), suffix: "Claude te pose une question")
                Spacer()
                if qs.count > 1 { Text("\(index + 1)/\(qs.count)").font(Fonts.caption).monospacedDigit().foregroundStyle(Color.muted) }
            }
            if let q {
                Text(q.question).font(Fonts.lead).lineLimit(2)
                if writing {
                    HStack(spacing: 6) {
                        ComposeField(text: $other, placeholder: "Ta réponse…", onSubmit: { pick(other) },
                                     onEditing: { store.setComposing($0) }, focus: focusOther, onFocused: { focusOther = false })
                            .frame(height: 18)
                        Button("Envoyer") { pick(other) }.buttonStyle(Pill(primary: true))
                            .disabled(other.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.white.opacity(0.09)))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(q.options, id: \.label) { o in
                                let on = picked.contains(o.label)
                                Button { q.multi ? toggle(o.label) : pick(o.label) } label: {
                                    HStack(spacing: 4) {
                                        if q.multi { Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 10.5)) }
                                        Text(o.label)
                                    }
                                }
                                .buttonStyle(Pill(primary: on))
                                .help(o.detail)
                            }
                            Button("Autre…") { writing = true; focusOther = true }.buttonStyle(Pill())
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if q?.multi == true && !writing {
                    Button("Valider") { pick(picked.sorted().joined(separator: ", ")) }.buttonStyle(Pill(primary: true)).disabled(picked.isEmpty)
                }
                Button("Répondre dans \(store.session(permission.session)?.place ?? "VS Code")") { store.answerElsewhere() }
                    .buttonStyle(.plain).font(Fonts.caption).foregroundStyle(Color.faint)
                Spacer()
                if let d = q?.options.first(where: { picked.contains($0.label) })?.detail, !d.isEmpty {
                    Text(d).font(Fonts.caption).foregroundStyle(Color.muted).lineLimit(1)
                }
            }
        }
        .padding(.leading, 100)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
    }

    private func toggle(_ label: String) {
        if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
        Sound.shared.play("tick")
    }

    /// Réponse à la question en cours ; à la dernière, tout part à Claude.
    private func pick(_ answer: String) {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let qs = permission.questions
        guard !a.isEmpty, qs.indices.contains(index) else { return }
        answers[qs[index].question] = a
        if index + 1 < qs.count {
            index += 1
            picked = []
            other = ""
            writing = false
            Sound.shared.play("tick")
        } else {
            store.answerQuestion(answers)
        }
    }
}

/// Le plan de Claude : le lire, puis Valider, demander des changements (écrits) ou Refuser.
struct PlanView: View {
    @ObservedObject var store: Store
    let permission: Permission
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Who(session: store.session(permission.session), suffix: "Claude propose un plan")
            ScrollView(.vertical) {
                Text((try? AttributedString(markdown: permission.plan,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(permission.plan))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.soft)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(Color.sunken))
            .overlay(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).strokeBorder(.white.opacity(0.05)))
            HStack(spacing: 6) {
                ComposeField(text: $feedback, placeholder: "Ce qu'il faut changer (facultatif)…",
                             onSubmit: { if !feedback.isEmpty { store.revisePlan(feedback) } }, onEditing: { store.setComposing($0) })
                    .frame(height: 18)
                    .padding(.leading, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.white.opacity(0.08)))
                if feedback.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Refuser") { store.revisePlan(nil) }.buttonStyle(Pill())
                } else {
                    Button("Modifier") { store.revisePlan(feedback) }.buttonStyle(Pill())
                }
                Button("Valider le plan") { store.approvePlan() }.buttonStyle(Pill(primary: true))
            }
            HStack {
                Button("Répondre dans \(store.session(permission.session)?.place ?? "VS Code")") { store.answerElsewhere() }
                    .buttonStyle(.plain).font(Fonts.caption).foregroundStyle(Color.faint)
                Spacer()
                Text("⌥⇧Y valider · ⌥⇧N refuser").font(Fonts.caption).foregroundStyle(Color.faint)
            }
        }
        .padding(.leading, 100)
        .padding(.trailing, 16)
        .padding(.vertical, 11)
    }
}

/// Projets Claude Code récents : reprendre une session, ou en lancer une nouvelle dans un projet.
struct ProjectsPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var projects = Projects.shared
    @State private var open: String?

    var body: some View {
        Card(wash: Color(hex: "#3B9EFF", 0.14)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Projets récents").font(Fonts.labelBold).foregroundStyle(Color.muted)
                    if projects.loading { ProgressView().controlSize(.mini) }
                    Spacer()
                    Button("Résumé du jour") { store.goTo(.recap); Recap.shared.make() }.buttonStyle(Pill())
                }
                if projects.list.isEmpty && !projects.loading {
                    Text("Pas encore de session Claude Code sur ce Mac.").font(Fonts.lead)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(projects.list) { p in ProjectRow(project: p, open: $open) }
                    }
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
            .padding(.vertical, 11)
        }
        .onAppear { projects.refresh() }
    }
}

struct ProjectRow: View {
    let project: Projects.Project
    @Binding var open: String?
    @State private var hover = false

    var body: some View {
        let expanded = open == project.id
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Color(hex: "#7CC7FF"))
                Text(project.name).font(Fonts.labelBold).lineLimit(1)
                Text(ago(project.last)).font(Fonts.caption).foregroundStyle(Color.faint)
                Spacer(minLength: 4)
                Button { Projects.shared.start(in: project) } label: { Image(systemName: "plus").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(MiniIcon()).help("Nouvelle session Claude dans \(project.name)")
                    .accessibilityLabel("Nouvelle session dans \(project.name)")
                if let c = project.sessions.first {
                    Button("Reprendre") { Projects.shared.resume(c, in: project) }.buttonStyle(Chip())
                        .help("Reprendre : \(c.title)")
                }
                Button { withAnimation(.easeOut(duration: 0.2)) { open = expanded ? nil : project.id } } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .buttonStyle(MiniIcon()).help("Les sessions de ce projet")
                .accessibilityLabel(expanded ? "Masquer les sessions" : "Voir les sessions")
            }
            if expanded {
                ForEach(project.sessions) { c in
                    Button { Projects.shared.resume(c, in: project) } label: {
                        HStack(spacing: 6) {
                            Text(c.title).font(Fonts.caption).foregroundStyle(Color.soft).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ago(c.date)).font(Fonts.caption).foregroundStyle(Color.faint)
                        }
                        .padding(.leading, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverDim())
                    .help("Reprendre cette session dans VS Code")
                    .contextMenu {
                        Button("Reprendre dans VS Code") { Projects.shared.resume(c, in: project) }
                        Button("Reprendre dans le Terminal") { Projects.shared.resumeInTerminal(c, in: project) }
                    }
                }
            } else if let c = project.sessions.first {
                Text(c.title).font(Fonts.caption).foregroundStyle(Color.faint).lineLimit(1).padding(.leading, 19)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0.04)))
        .onHover { hover = $0 }
    }

    private func ago(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// Le résumé de la journée, écrit par Claude : à copier pour un client ou pour demain.
struct RecapPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var recap = Recap.shared

    var body: some View {
        Card(wash: Color(hex: "#A78BFA", 0.18)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Ta journée").font(Fonts.labelBold)
                    Text(recap.day.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(Fonts.caption).foregroundStyle(Color.faint)
                    Spacer()
                    if recap.busy { ProgressView().controlSize(.mini) }
                }
                ScrollView(.vertical) {
                    Text(recap.busy ? "Claude relit ta journée…" : recap.text.isEmpty ? "Clique sur Résumer." : markdown(recap.text))
                        .font(Fonts.label)
                        .foregroundStyle(recap.text.isEmpty || recap.busy ? Color.faint : Color.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(Color.sunken))
                HStack(spacing: 8) {
                    Button("Copier") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recap.text, forType: .string)
                        store.say("Résumé copié ✓", ok: true)
                    }
                    .buttonStyle(Pill(primary: true)).disabled(recap.text.isEmpty || recap.busy)
                    Button(recap.text.isEmpty ? "Résumer" : "Refaire") { recap.make() }.buttonStyle(Pill()).disabled(recap.busy)
                    Spacer()
                    Text("Tes demandes à Claude et tes commits du jour").font(Fonts.caption).foregroundStyle(Color.faint)
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
            .padding(.vertical, 11)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct ApprovalPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: Color(hex: store.currentPermission?.kind == .tool ? "#F5A524" : "#22D3EE", 0.36)) {
            if let p = store.currentPermission, p.kind == .question {
                QuestionView(store: store, permission: p).id(p.id)
            } else if let p = store.currentPermission, p.kind == .plan {
                PlanView(store: store, permission: p).id(p.id)
            } else if let p = store.currentPermission {
                VStack(alignment: .leading, spacing: 9) {
                    Who(session: store.session(p.session), suffix: "Claude \(p.title)")
                    Text(p.detail)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06)))
                    HStack(spacing: 8) {
                        Button("Refuser") { store.answer("deny") }.buttonStyle(Pill())
                        Button("Toujours autoriser") { store.answer("always") }.buttonStyle(Pill())
                        Button("Autoriser") { store.answer("allow") }.buttonStyle(Pill(primary: true))
                        if store.permissions.count > 1 {
                            Text("+\(store.permissions.count - 1) en attente").font(Fonts.caption).foregroundStyle(Color.muted)
                        }
                        Spacer(minLength: 4)
                        Text("⌥⇧Y · ⌥⇧N").font(Fonts.caption).foregroundStyle(Color.faint)
                            .help("⌥⇧Y autoriser, ⌥⇧N refuser, depuis n'importe quelle app")
                    }
                }
                .padding(.leading, 100)
                .padding(.trailing, 16)
            }
        }
    }
}

struct FinishedPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: Color(hex: "#34D399", 0.5)) {
            VStack(alignment: .leading, spacing: 8) {
                Who(session: store.focused, suffix: "Claude a terminé")
                big(store.focused?.history.last(where: { $0.hasPrefix("«") }).map { "C'est fait : \($0)" } ?? "C'est prêt.")
                if let t = store.focused?.turn { TurnSummary(turn: t) }
                HStack(spacing: 8) {
                    if let s = store.focused {
                        Button("Voir dans \(s.place)") { store.jump(to: s) }.buttonStyle(Pill(primary: true))
                    }
                    Button("OK") { store.dismissCurrent() }.buttonStyle(Pill())
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
    }
}

/// « 4 fichiers en 6 min · +120 −34 · 12k tokens · contexte 84k », puis les fichiers à ouvrir dans VS Code.
struct TurnSummary: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(turn.text).foregroundStyle(Color.muted)
                if let a = turn.added, let r = turn.removed, a + r > 0 {
                    (Text("+\(a) ").foregroundColor(.success) + Text("−\(r)").foregroundColor(.danger))
                        .monospacedDigit()
                        .help("Lignes modifiées dans ces fichiers depuis le dernier commit")
                }
                if let t = turn.tokens {
                    Text("· " + t).foregroundStyle(Color.faint)
                        .help("Tokens écrits par Claude pendant la demande · taille du contexte qu'il relit à chaque message")
                }
            }
            if !turn.files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(turn.files.prefix(4), id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { open(path) }
                            .buttonStyle(Chip())
                            .frame(maxWidth: 120)
                            .help("Ouvrir \(path) dans VS Code")
                    }
                    if turn.files.count > 4 { Text("+\(turn.files.count - 4)").foregroundStyle(Color.muted) }
                }
            }
        }
        .font(Fonts.label)
        .lineLimit(1)
    }

    private func open(_ path: String) {
        var c = URLComponents()
        c.scheme = "vscode"
        c.host = "file"
        c.path = path
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}

struct ErrorPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: Color(hex: "#F4505E", 0.55)) {
            VStack(alignment: .leading, spacing: 8) {
                Who(session: store.focused, suffix: "Claude Code")
                big("Ça s'est arrêté.")
                sub(store.focused?.message ?? "", red: true)
                HStack(spacing: 8) {
                    if let s = store.focused {
                        Button("Voir dans \(s.place)") { store.jump(to: s) }.buttonStyle(Pill(primary: true))
                    }
                    Button("OK") { store.dismissCurrent() }.buttonStyle(Pill())
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
    }
}
