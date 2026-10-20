import AppKit
import ServiceManagement
import SwiftUI

/// Fenêtre de réglages (clic droit sur le bonhomme, ou la roue dentée de l'encoche).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Réglages d'Encoche"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(store: Store.shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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

    var body: some View {
        Form {
            Section("Raccourcis") {
                Picker("Écrire à Claude", selection: $summon) {
                    ForEach(HotKey.Summon.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: summon) { _, v in HotKey.Summon.current = v }
                Text("Avec ⇧ en plus : dicter. Pendant une demande d'autorisation : ⌥⇧Y autoriser, ⌥⇧N refuser.")
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

            Section("Général") {
                Toggle("Sons", isOn: Binding(get: { Sound.shared.on }, set: { Sound.shared.on = $0; store.objectWillChange.send() }))
                Toggle("Ouvrir au démarrage du Mac", isOn: Binding(get: { store.openAtLogin }, set: { store.setLoginItem($0) }))
                HStack {
                    Text(store.hooked ? "Branchée à Claude Code" : "Pas branchée à Claude Code")
                    Spacer()
                    Button(store.hooked ? "Débrancher" : "Brancher…") { store.setHooked(!store.hooked) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
        .onChange(of: store.favorites) { _, v in UserDefaults.standard.set(v, forKey: "favorites") }
    }
}
