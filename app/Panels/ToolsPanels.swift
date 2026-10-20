import AppKit
import SwiftUI

// Onglet Outils : terminal, serveurs et santé du Mac, texte IA, miroir, prompteur.

/// Onglet Dev : serveurs locaux à gauche, santé du Mac à droite.
/// Onglet Dev : le mini-terminal, ou les serveurs locaux et la santé du Mac.
struct DevPanel: View {
    @ObservedObject var store: Store

    var body: some View {
        switch store.tool {
        case .terminal: TerminalPanel(store: store)
        case .servers: ServersPanel(store: store)
        case .text: TextAIPanel(store: store)
        case .mirror: MirrorPanel(store: store)
        case .prompter: PrompterPanel(store: store)
        }
    }
}

struct DevSwitch: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Store.Tool.allCases, id: \.self) { t in
                let on = t == store.tool
                Button {
                    guard !on else { return }
                    Sound.shared.play("tick")
                    withAnimation(Store.openAnimation) { store.tool = t }
                } label: {
                    Text(t.rawValue)
                        .font(Fonts.caption.weight(.semibold))
                        .foregroundStyle(on ? Color.ink : Color.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(.white.opacity(on ? 0.14 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
        .fixedSize()
    }
}

/// Mini-terminal : dossier, résultat en direct, commande (Entrée), ↑/↓ pour l'historique.
struct TerminalPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var shell = Shell.shared

    var body: some View {
        Card(wash: Color(hex: "#34D399", 0.12)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    DevSwitch(store: store)
                    folderMenu
                    Spacer(minLength: 4)
                    if shell.running {
                        ProgressView().controlSize(.mini)
                    } else if let code = shell.lastExit {
                        Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(code == 0 ? Color.success : Color.danger)
                            .help(code == 0 ? "Réussi" : "Code de sortie \(code)")
                    }
                    Button { shell.clear() } label: { Image(systemName: "trash").font(.system(size: 10.5, weight: .semibold)) }
                        .buttonStyle(MiniIcon()).help("Effacer").accessibilityLabel("Effacer le résultat")
                    Button { shell.openInTerminal() } label: { Image(systemName: "macwindow").font(.system(size: 10.5, weight: .semibold)) }
                        .buttonStyle(MiniIcon()).help("Ouvrir ce dossier dans le Terminal").accessibilityLabel("Ouvrir dans le Terminal")
                }
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        Text(shell.output.isEmpty ? "Tape une commande (git status, npm run build…) : le résultat s'affiche ici."
                                                  : shell.output.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(shell.output.isEmpty ? Color.faint : Color.soft)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("fin")
                    }
                    .onChange(of: shell.output.count) { _, _ in reader.scrollTo("fin", anchor: .bottom) }
                    .onAppear { reader.scrollTo("fin", anchor: .bottom) }
                }
                .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(Color.sunken))
                .overlay(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).strokeBorder(.white.opacity(0.05)))
                HStack(spacing: 6) {
                    Text("$").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Color.success)
                    ComposeField(text: $shell.command, placeholder: "Commande dans \(shell.folderName)… (Entrée)",
                                 onSubmit: { shell.run() }, onEditing: { store.setComposing($0) }, onArrow: { shell.browse($0) })
                        .frame(height: 18)
                    if shell.running {
                        Button { shell.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 9.5, weight: .bold)) }
                            .buttonStyle(MiniIcon()).help("Arrêter (comme ⌃C)").accessibilityLabel("Arrêter la commande")
                    } else {
                        Button { shell.run() } label: { Image(systemName: "return").font(.system(size: 10.5, weight: .bold)) }
                            .buttonStyle(MiniIcon()).help("Lancer (Entrée)").accessibilityLabel("Lancer la commande")
                            .disabled(shell.command.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.white.opacity(store.composing ? 0.11 : 0.07)))
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
    }

    /// Le dossier : projets des sessions Claude, dossiers récents, ou au choix.
    private var folderMenu: some View {
        Menu {
            let projects = Array(Set(store.sessions.map(\.cwd))).sorted()
            if !projects.isEmpty {
                Section("Projets Claude") {
                    ForEach(projects, id: \.self) { p in Button(URL(fileURLWithPath: p).lastPathComponent) { shell.setFolder(URL(fileURLWithPath: p)) } }
                }
            }
            let recent = shell.recent.filter { !projects.contains($0) }
            if !recent.isEmpty {
                Section("Récents") {
                    ForEach(recent, id: \.self) { p in Button(URL(fileURLWithPath: p).lastPathComponent) { shell.setFolder(URL(fileURLWithPath: p)) } }
                }
            }
            Divider()
            Button("Dossier personnel") { shell.setFolder(FileManager.default.homeDirectoryForCurrentUser) }
            Button("Choisir un dossier…") { shell.chooseFolder() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").font(.system(size: 10))
                Text(shell.folderName).lineLimit(1).truncationMode(.middle).frame(maxWidth: 90)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Fonts.caption.weight(.medium))
            .foregroundStyle(Color.soft)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(shell.folder.path)
    }
}

/// Texte IA : le texte sélectionné (⌥⇧R) ou un fichier de l'étagère, une action, le résultat à remplacer ou copier.
struct TextAIPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var ai = TextAI.shared

    var body: some View {
        Card(wash: Color(hex: "#A78BFA", 0.18)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    DevSwitch(store: store)
                    Spacer(minLength: 4)
                    if !ai.origin.isEmpty { Text(ai.origin).font(Fonts.caption).foregroundStyle(Color.faint).lineLimit(1) }
                }
                if ai.source.isEmpty {
                    Spacer(minLength: 0)
                    Text(ai.error ?? "Sélectionne un texte dans n'importe quelle app, puis ⌥⇧R.").font(Fonts.lead)
                    Text("Corriger, reformuler, raccourcir, traduire… Le résultat remplace ta sélection. "
                         + "Dans l'étagère : clic droit sur un PDF → Résumer avec l'IA.").font(Fonts.label).foregroundStyle(Color.muted)
                    Spacer(minLength: 0)
                } else {
                    Text(ai.source)
                        .font(Fonts.caption).foregroundStyle(Color.muted).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(TextAI.Action.allCases) { a in
                                Button { ai.run(a) } label: {
                                    HStack(spacing: 4) {
                                        if ai.busy == a { ProgressView().controlSize(.mini) }
                                        Text(a.rawValue)
                                    }
                                }
                                .buttonStyle(Chip())
                                .disabled(ai.busy != nil)
                            }
                        }
                    }
                    ScrollView(.vertical) {
                        Text(ai.busy != nil ? "Claude écrit…" : ai.error ?? (ai.result.isEmpty ? "Choisis une action." : ai.result))
                            .font(Fonts.label)
                            .foregroundStyle(ai.result.isEmpty || ai.busy != nil ? Color.faint : ai.error != nil ? Color.danger : Color.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(Color.sunken))
                    HStack(spacing: 8) {
                        if ai.canReplace { Button("Remplacer la sélection") { ai.replace() }.buttonStyle(Pill(primary: true)) }
                        Button("Copier") { ai.copy() }.buttonStyle(Pill(primary: !ai.canReplace)).disabled(ai.result.isEmpty)
                        Spacer()
                        Text("⌥⇧R").font(Fonts.caption).foregroundStyle(Color.faint).help("Sur un texte sélectionné, dans n'importe quelle app")
                    }
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
    }
}

/// Miroir : la caméra (en miroir) pour vérifier sa tête avant une visio. Éteinte dès que l'encoche se ferme.
struct MirrorPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var camera = CameraAccess.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                DevSwitch(store: store)
                if camera.denied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("La caméra est refusée pour Encoche.").font(Fonts.lead)
                        Text("Autorise-la dans Réglages Système → Confidentialité et sécurité → Caméra.").font(Fonts.label).foregroundStyle(Color.muted)
                        Button("Ouvrir les Réglages") { camera.openSettings() }.buttonStyle(Pill(primary: true))
                    }
                } else {
                HStack(alignment: .top, spacing: 14) {
                    MirrorView()
                        .frame(width: 256, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Prêt pour la visio ?").font(Fonts.lead)
                        Text("La caméra s'éteint dès que l'encoche se ferme.").font(Fonts.label).foregroundStyle(Color.muted)
                        Text("Première fois : autorise la caméra pour Encoche.").font(Fonts.caption).foregroundStyle(Color.faint)
                    }
                }
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
    }
}

/// Prompteur : écrire son texte, puis il défile juste sous la caméra (invisible dans les partages d'écran).
struct PrompterPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var p = Prompter.shared

    var body: some View {
        Card {
            if p.showing { reading } else { editing }
        }
    }

    private var editing: some View {
        VStack(alignment: .leading, spacing: 7) {
            DevSwitch(store: store)
            ScriptEditor(text: $p.script, onEditing: { store.setComposing($0) })
                .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(Color.sunken))
                .overlay(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).strokeBorder(.white.opacity(0.06)))
            HStack(spacing: 8) {
                Text("Taille").font(Fonts.caption).foregroundStyle(Color.muted)
                Button { p.size = max(14, p.size - 2) } label: { Image(systemName: "textformat.size.smaller") }.buttonStyle(MiniIcon())
                Button { p.size = min(40, p.size + 2) } label: { Image(systemName: "textformat.size.larger") }.buttonStyle(MiniIcon())
                Text("Vitesse").font(Fonts.caption).foregroundStyle(Color.muted).padding(.leading, 6)
                Button { p.faster(-6) } label: { Image(systemName: "tortoise.fill") }.buttonStyle(MiniIcon()).help("Plus lent")
                Button { p.faster(6) } label: { Image(systemName: "hare.fill") }.buttonStyle(MiniIcon()).help("Plus rapide")
                Spacer()
                Button("Lancer") { p.start() }.buttonStyle(Pill(primary: true))
            }
        }
        .padding(.leading, 100)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    /// Le texte monte doucement ; il commence juste sous la caméra, là où tu regardes.
    private var reading: some View {
        VStack(spacing: 6) {
            TimelineView(.animation) { tl in
                GeometryReader { g in
                    Text(p.script)
                        .font(.system(size: p.size, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .lineSpacing(p.size * 0.25)
                        .frame(width: g.size.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { t in Color.clear.preference(key: TextHeight.self, value: t.size.height) })
                        .offset(y: 10 - p.offset(at: tl.date))
                }
            }
            .onPreferenceChange(TextHeight.self) { p.textHeight = $0 }
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            HStack(spacing: 8) {
                Button { p.toggle() } label: { Image(systemName: p.playing ? "pause.fill" : "play.fill") }.buttonStyle(RoundControl(primary: true))
                    .help(p.playing ? "Pause" : "Reprendre")
                Button { p.restart() } label: { Image(systemName: "backward.end.fill") }.buttonStyle(RoundControl()).help("Depuis le début")
                Button { p.faster(-6) } label: { Image(systemName: "tortoise.fill") }.buttonStyle(RoundControl()).help("Plus lent")
                Button { p.faster(6) } label: { Image(systemName: "hare.fill") }.buttonStyle(RoundControl()).help("Plus rapide")
                Spacer()
                Button("Terminer") { p.stop() }.buttonStyle(Pill())
            }
        }
        .padding(.leading, 100)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }
}

struct TextHeight: PreferenceKey {
    static let defaultValue = 0.0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

struct ServersPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var dev = DevMonitor.shared
    @ObservedObject var bt = Devices.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                DevSwitch(store: store)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        if dev.servers.isEmpty {
                            Text(dev.scanned ? "Aucun serveur ne tourne." : "Je regarde…").font(Fonts.lead)
                            Text("Lance npm run dev (ou autre) : il apparaîtra ici.").font(Fonts.label).foregroundStyle(Color.muted)
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 4) { ForEach(dev.servers) { s in ServerRow(server: s) } }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Gauge(label: "CPU", value: dev.health.cpu)
                        Gauge(label: "Mémoire", value: dev.health.memory)
                        if let b = dev.health.battery {
                            Gauge(label: dev.health.charging ? "Batterie ⚡︎" : "Batterie", value: Double(b) / 100, invert: true)
                        }
                        HStack {
                            Text("Chaleur").foregroundStyle(Color.muted)
                            Spacer()
                            Text(thermal.0).foregroundStyle(thermal.1)
                        }
                        .font(Fonts.caption)
                        ForEach(bt.devices.filter(\.hasBattery)) { d in
                            HStack(spacing: 4) {
                                Image(systemName: d.name.lowercased().contains("airpods") ? "airpods" : "headphones")
                                Text(d.summary).lineLimit(1)
                            }
                            .font(Fonts.caption)
                            .foregroundStyle(Color.soft)
                            .help(d.name)
                        }
                    }
                    .frame(width: 160)
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
            .padding(.vertical, 11)
        }
        .onAppear { dev.watch(true); bt.refresh() }
        .onDisappear { dev.watch(false) }
    }

    private var thermal: (String, Color) {
        switch dev.health.thermal {
        case .nominal: ("Normale", .success)
        case .fair: ("Tiède", .warning)
        case .serious: ("Chaud", .danger)
        case .critical: ("Brûlant", .danger)
        @unknown default: ("—", .muted)
        }
    }
}

struct ServerRow: View {
    let server: DevMonitor.Server
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.success).frame(width: 6, height: 6)
            Text(":\(server.port)").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            Text(server.project.isEmpty ? server.command : "\(server.project) · \(server.command)")
                .font(Fonts.caption).foregroundStyle(Color.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button { DevMonitor.shared.open(server) } label: { Image(systemName: "safari").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(MiniIcon())
                .help("Ouvrir http://localhost:\(server.port)")
                .accessibilityLabel("Ouvrir le port \(server.port) dans le navigateur")
            Button { DevMonitor.shared.stop(server) } label: { Image(systemName: "stop.fill").font(.system(size: 9.5, weight: .bold)) }
                .buttonStyle(MiniIcon())
                .help("Arrêter ce serveur (\(server.command), pid \(server.pid))")
                .accessibilityLabel("Arrêter le serveur du port \(server.port)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0.04)))
        .onHover { hover = $0 }
    }
}
