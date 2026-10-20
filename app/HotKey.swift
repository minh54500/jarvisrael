import AppKit
import Carbon

/// Raccourcis globaux : ils marchent depuis n'importe quelle app, sans autorisation particulière.
/// ⌥Espace ouvre l'encoche prête à écrire à Claude ; ⌥⇧Espace l'ouvre et lance la dictée.
enum HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var held = Set<UInt32>()
    private static var lastPress: [UInt32: Date] = [:]
    private static var installed = false

    static func register(id: UInt32, key: Int, modifiers: Int, _ action: @escaping () -> Void) {
        if !installed {
            installed = true
            var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id, pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                DispatchQueue.main.async { HotKey.handle(id, pressed: pressed) }
                return noErr
            }, 2, &specs, nil, nil)
        }
        unregister(id)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x454E_4348, id: id),  // 'ENCH'
                            GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
    }

    static func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    // MARK: Raccourci pour écrire à Claude (au choix dans les réglages)

    enum Summon: Int, CaseIterable, Identifiable {
        case option, controlOption, control, none
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .option: "⌥ Espace"
            case .controlOption: "⌃⌥ Espace"
            case .control: "⌃ Espace"
            case .none: "Aucun"
            }
        }
        var modifiers: Int? {
            switch self {
            case .option: optionKey
            case .controlOption: controlKey | optionKey
            case .control: controlKey
            case .none: nil
            }
        }
        static var current: Summon {
            get { Summon(rawValue: UserDefaults.standard.integer(forKey: "hotkey")) ?? .option }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey"); HotKey.installSummon() }
        }
    }

    /// Le raccourci choisi écrit à Claude ; avec ⇧ en plus, il lance la dictée.
    static func installSummon() {
        unregister(1)
        unregister(2)
        guard let m = Summon.current.modifiers else { return }
        register(id: 1, key: kVK_Space, modifiers: m) { MainActor.assumeIsolated { Store.shared.summon(dictate: false) } }
        register(id: 2, key: kVK_Space, modifiers: m | shiftKey) { MainActor.assumeIsolated { Store.shared.summon(dictate: true) } }
    }

    /// ⌥⇧Y autoriser, ⌥⇧N refuser : actifs seulement pendant qu'une demande attend (⌥N tape « ~ »
    /// sur un clavier français, on ne le prend jamais).
    static func approvalKeys(_ on: Bool) {
        guard on else { unregister(3); unregister(4); return }
        register(id: 3, key: kVK_ANSI_Y, modifiers: optionKey | shiftKey) { MainActor.assumeIsolated { Store.shared.answerFromKeyboard("allow") } }
        register(id: 4, key: kVK_ANSI_N, modifiers: optionKey | shiftKey) { MainActor.assumeIsolated { Store.shared.answerFromKeyboard("deny") } }
    }

    /// Touches gardées enfoncées : une seule action par appui (pas de répétition qui ouvre, ferme, rouvre).
    /// Une répétition arrive toutes les quelques dizaines de ms ; au-delà de 0,6 s sans nouvelle, c'est un
    /// nouvel appui (même si le relâchement s'est perdu).
    private static func handle(_ id: UInt32, pressed: Bool) {
        guard pressed else { held.remove(id); return }
        let now = Date()
        defer { lastPress[id] = now }
        if held.contains(id), let last = lastPress[id], now.timeIntervalSince(last) < 0.6 { return }
        held.insert(id)
        actions[id]?()
    }
}
