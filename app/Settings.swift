import AppKit
import ServiceManagement
import SwiftUI

/// Fenêtre de réglages (clic droit sur le bonhomme, ou la roue dentée de l'encoche), en onglets.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    enum Tab: String, CaseIterable {
        case general = "Général", mochi = "Bonhomme", keys = "Raccourcis", care = "Rappels", friends = "Potes", update = "Mise à jour"
        var icon: String {
            switch self {
            case .general: "gearshape.fill"
            case .mochi: "face.smiling.inverse"
            case .keys: "command"
            case .care: "heart.fill"
            case .friends: "person.2.fill"
            case .update: "arrow.down.circle.fill"
            }
        }
    }

    final class Selection: ObservableObject {
        static let shared = Selection()
        @Published var tab = Tab.general
    }

    static func show(_ tab: Tab? = nil) {
        if let tab { Selection.shared.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Réglages d'Encoche"
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Color.surface)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(store: Store.shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Barre d'onglets des Réglages, comme celle de l'encoche : grande icône, nom, pastille qui glisse.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsWindow.Tab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsWindow.Tab.allCases, id: \.self) { t in
                let on = t == selection
                Button { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { selection = t } } label: {
                    VStack(spacing: 5) {
                        Image(systemName: t.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(on ? Color(hex: "#FF8BC4") : Color.muted)
                            .frame(height: 22)
                        Text(t.rawValue)
                            .font(.system(size: 11, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Color.ink : Color.muted)
                    }
                    .frame(width: 80, height: 56)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.09))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
                                .matchedGeometryEffect(id: "onglet", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.rawValue)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }
}

/// Couleur du nuancier → « #RRGGBB ».
private func hexString(_ c: Color) -> String {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .systemPink
    return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
}

/// Le bonhomme dans un skin donné, immobile (aperçu des Réglages).
private struct SkinPreview: View {
    let skin: Skin
    let tint: String?
    @State private var mochi: Mochi?

    var body: some View {
        Canvas { ctx, size in
            mochi?.draw(ctx, cx: size.width / 2, cy: size.height / 2 + 5, hb: 40)
        }
        .onAppear {
            let m = Mochi(skin: skin, tint: tint, now: CACurrentMediaTime())
            m.update(CACurrentMediaTime() + 0.016)
            mochi = m
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var summon = HotKey.Summon.current
    @AppStorage("care") private var care = true
    @AppStorage("care.pause") private var pause = true
    @AppStorage("care.pauseMin") private var pauseMin = 50
    @AppStorage("care.water") private var water = true
    @AppStorage("care.waterMin") private var waterMin = 90
    @AppStorage("care.night") private var night = true
    @AppStorage("care.health") private var health = true
    @AppStorage("ntfy.on") private var phone = false
    @AppStorage("ntfy.topic") private var topic = ""
    @AppStorage("ntfy.away") private var away = true
    @State private var tested = false
    @AppStorage("friends.on") private var friendsOn = false
    @AppStorage("friends.name") private var friendsName = ""
    @AppStorage("friends.group") private var friendsGroup = ""
    @ObservedObject private var cam = FriendCam.shared
    @AppStorage("friends.music") private var musicShare = false
    @AppStorage("annotate") private var annotate = true
    @ObservedObject private var awake = Awake.shared
    @AppStorage("openIn") private var openIn = OpenIn.vscode
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var selection = SettingsWindow.Selection.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection.tab)
            Divider().opacity(0.5)
            Group {
            if selection.tab == .general {
            Form {
            Section("Général") {
                Toggle("Sons", isOn: Binding(get: { Sound.shared.on }, set: { Sound.shared.on = $0; store.objectWillChange.send() }))
                Toggle("Ouvrir au démarrage du Mac", isOn: Binding(get: { store.openAtLogin }, set: { store.setLoginItem($0) }))
                Toggle("Cacher l'encoche dans les partages d'écran et les captures", isOn: Binding(
                    get: { store.hiddenInShares },
                    set: { UserDefaults.standard.set($0, forKey: "privacy.hide"); store.applyPrivacy($0); store.objectWillChange.send() }))
                Toggle("Annoter mes captures avant de les envoyer", isOn: $annotate)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Garder le Mac éveillé capot fermé")
                        Text(awake.lidReady ? "Installé : la goutte « tasse » peut garder le Mac éveillé même capot fermé."
                             : "Demande ton mot de passe une fois (règle limitée à « pmset disablesleep »).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if awake.lidReady { Button("Retirer") { awake.removeRule() } } else { Button("Installer") { awake.setLidMode(true) } }
                }
                Picker("Nouvelles sessions Claude Code dans", selection: $openIn) {
                    ForEach(OpenIn.allCases) { Text($0.name).tag($0) }
                }
                if openIn == .app && !ClaudeApp.installed {
                    HStack {
                        Text("L'app Claude n'est pas installée sur ce Mac.").font(.caption).foregroundStyle(.secondary)
                        Link("La télécharger", destination: URL(string: "https://claude.ai/download")!).font(.caption)
                    }
                }
                HStack {
                    Text(store.hooked ? "Branchée à Claude Code" : "Pas branchée à Claude Code")
                    Spacer()
                    Button(store.hooked ? "Débrancher" : "Brancher…") { store.setHooked(!store.hooked) }
                }
                Button("Revoir la visite guidée") { store.startWelcome() }
            }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            }  // general

            if selection.tab == .mochi {
            Form {
            Section("Skin du bonhomme") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(Skin.all) { s in
                        let on = s.id == store.mochi.skin.id
                        Button { store.setSkin(s) } label: {
                            VStack(spacing: 4) {
                                SkinPreview(skin: s, tint: store.mochi.tint).frame(width: 96, height: 70).id((store.mochi.tint ?? "") + s.id)
                                Text(s.name).font(.callout.weight(on ? .semibold : .regular))
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skin \(s.name)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                HStack(spacing: 7) {
                    Text("Couleur")
                    Spacer()
                    Button { store.setColor(nil) } label: {
                        Text("Skin").font(.caption).padding(.horizontal, 6).frame(height: 20)
                            .background(Capsule().strokeBorder(store.mochi.tint == nil ? Color.accentColor : .secondary.opacity(0.4), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help("Les couleurs du skin")
                    ForEach(Skin.colors, id: \.hex) { c in
                        Button { store.setColor(c.hex) } label: {
                            Circle().fill(Color(hex: c.hex)).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(store.mochi.tint == c.hex ? Color.primary : .clear, lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help(c.name)
                        .accessibilityLabel("Couleur \(c.name)")
                    }
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: store.mochi.tint ?? Skin.current.aura) },
                        set: { store.setColor(hexString($0)) }), supportsOpacity: false)
                        .labelsHidden()
                        .help("N'importe quelle couleur")
                }
                Text("Tes potes voient ton skin et ta couleur dans leur onglet Potes.").font(.caption).foregroundStyle(.secondary)
            }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            }  // mochi

            if selection.tab == .keys {
            Form {
            Section("Raccourcis") {
                Picker("Écrire à Claude", selection: $summon) {
                    ForEach(HotKey.Summon.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: summon) { _, v in HotKey.Summon.current = v }
                Text("Avec ⇧ en plus : dicter. ⌥⇧R : l'IA sur le texte sélectionné. Pendant une demande d'autorisation : ⌥⇧Y autoriser, ⌥⇧N refuser.")
                    .font(.caption).foregroundStyle(.secondary)
                if summon == .option {
                    Text("⌥ Espace remplace l'espace insécable du clavier français.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Prompts favoris") {
                ForEach(store.favorites.indices, id: \.self) { i in
                    HStack {
                        TextField("Message", text: Binding(get: { store.favorites.indices.contains(i) ? store.favorites[i] : "" },
                                                          set: { if store.favorites.indices.contains(i) { store.favorites[i] = $0 } }))
                            .textFieldStyle(.plain)
                        Button { store.favorites.remove(at: i) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Retirer ce favori")
                    }
                }
                Button("Ajouter un favori") { store.favorites.append("Nouveau message") }
            }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            }  // keys

            if selection.tab == .care {
            Form {
            Section("Rappels du bonhomme") {
                Toggle("Rappels activés", isOn: $care)
                Group {
                    Toggle("Pause", isOn: $pause)
                    Stepper("Toutes les \(pauseMin) min d'activité", value: $pauseMin, in: 20...120, step: 5).disabled(!pause)
                    Toggle("Verre d'eau", isOn: $water)
                    Stepper("Toutes les \(waterMin) min", value: $waterMin, in: 30...180, step: 15).disabled(!water)
                    Toggle("« Va dormir » entre 1 h et 5 h", isOn: $night)
                    Toggle("Batterie faible et Mac qui chauffe", isOn: $health)
                }
                .disabled(!care)
            }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            }  // care

            if selection.tab == .friends {
            Form {
            Section("Notifications sur le téléphone (ntfy)") {
                Toggle("Prévenir quand Claude a fini ou attend", isOn: $phone)
                HStack {
                    TextField("Sujet", text: $topic).textFieldStyle(.roundedBorder)
                    Button("Générer") { topic = Phone.newTopic() }
                }
                Toggle("Seulement si je ne suis pas devant le Mac", isOn: $away)
                Button(tested ? "Envoyée ✓" : "Envoyer une notification de test") {
                    Phone.post("Encoche", "Ça marche : tu recevras ici les nouvelles de Claude.", tag: "white_check_mark")
                    tested = true
                }
                .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Installe l'app ntfy sur ton téléphone et abonne-toi au même sujet. Le sujet sert de mot de passe : "
                     + "choisis-le difficile à deviner. Seuls le nom du projet et l'état sont envoyés, jamais tes messages.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Entre potes") {
                Toggle("Partager mon bonhomme avec mes potes", isOn: $friendsOn)
                TextField("Ton pseudo", text: $friendsName, prompt: Text("Ton prénom ou un surnom"))
                HStack {
                    TextField("Code du groupe", text: $friendsGroup).textFieldStyle(.roundedBorder)
                    Button("Créer") { friendsGroup = Friends.newGroup(); friendsOn = true }
                    Button("Copier") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(friendsGroup, forType: .string)
                    }
                    .disabled(friendsGroup.isEmpty)
                }
                Toggle("Montrer à mes potes ce que j'écoute sur Spotify", isOn: $musicShare)
                    .onChange(of: musicShare) { _, _ in Friends.shared.skinChanged() }
                Text("Crée un groupe et envoie le code à tes potes : ils le collent ici. Sont partagés, via ntfy.sh : ton pseudo, "
                     + "ton bonhomme et son humeur, si tu es sur ton Mac, « ne pas déranger », ton statut, si ta caméra est partagée "
                     + "et, si tu le coches, ce que tu écoutes. Jamais tes projets ni tes messages à Claude.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: friendsOn) { _, on in
                if on && friendsName.isEmpty { friendsName = NSFullUserName().components(separatedBy: " ").first ?? "" }
                Friends.shared.restart()
            }
            .onChange(of: friendsGroup) { _, _ in Friends.shared.restartSoon() }
            .onChange(of: friendsName) { _, _ in Friends.shared.restartSoon() }

            Section("Caméra entre potes") {
                Toggle("Partager ma caméra avec mes potes", isOn: Binding(get: { cam.sharing }, set: { cam.setSharing($0) }))
                    .disabled(!friendsOn || friendsGroup.isEmpty)
                if let problem = cam.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                Text("Image seulement, sans le son. Ceux qui ont le code du groupe te voient en direct quand ils ouvrent l'onglet Potes : ta caméra "
                     + "ne s'allume que pendant qu'ils regardent (lumière verte du Mac, et l'encoche te dit qui). L'image va "
                     + "directement de ton Mac au leur : pour ça, ton adresse internet leur est donnée. Sur certains réseaux "
                     + "(4G, Wi-Fi d'entreprise), ça ne passe pas.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            }  // friends

            if selection.tab == .update {
            Form {
            Section("Mise à jour") {
                LabeledContent("Version installée", value: updater.version)
                if updater.source == nil {
                    Text("Cette copie d'Encoche n'a pas été installée avec la commande d'installation : mets-la à jour à la main.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button(updater.checking ? "Je regarde…" : "Rechercher une mise à jour") { updater.check() }.disabled(updater.checking)
                        Spacer()
                        if let d = updater.lastCheck {
                            Text("Vérifié à \(d.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if updater.news.isEmpty {
                        Text(updater.lastCheck == nil ? "Encoche regarde toute seule toutes les 6 heures." : "Tu as la dernière version ✓")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Nouveautés :").font(.headline)
                        ForEach(updater.news.prefix(8), id: \.self) { Text("• " + $0).font(.callout) }
                        Button(updater.updating ? "Mise à jour en cours…" : "Mettre à jour et relancer") { updater.update() }
                            .buttonStyle(.borderedProminent).disabled(updater.updating)
                        Text("Encoche se ferme, se recompile (1 à 2 minutes) et se rouvre toute seule.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let p = updater.problem { Text(p).font(.caption).foregroundStyle(.red) }
                }
            }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            }  // update
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color.surface)
        .tint(Color(hex: "#FF8BC4"))
        .environment(\.colorScheme, .dark)
        .frame(width: 540, height: 620)
        .onChange(of: store.favorites) { _, v in UserDefaults.standard.set(v, forKey: "favorites") }
    }
}
