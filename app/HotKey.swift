import AppKit
import Carbon

/// Raccourcis globaux : ils marchent depuis n'importe quelle app, sans autorisation particulière.
/// ⌥Espace ouvre l'encoche prête à écrire à Claude ; ⌥⇧Espace l'ouvre et lance la dictée.
enum HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []
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
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x454E_4348, id: id),  // 'ENCH'
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
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
